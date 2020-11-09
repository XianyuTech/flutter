// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'image_provider.dart' as image_provider;
import 'image_stream.dart';

/// A use of completer cache for ExternalAdapterImageStreamCompleter is considering such
/// situation. Normally Apps using external adapter might turn Flutter's ImageCache to zero.
/// In that case no completer would be cached in ImageCache. But there are scenes such as 
/// multiple commodity detail pages using the same banner, button images or icons(Previous 
/// detail page and widgets still in stack). Because no completer is cached in ImageCache, 
/// so new ExternalAdapterImageStreamCompleter will be created to load icons or images of 
/// the second commodity detail page and redundant textures will be uploaded to GPU.
/// By using this cache, we put alive ExternalAdapterImageStreamCompleter in it and solve 
/// this problem. When the last listener is removed from the completer, the completer will
/// also be removed form _completerCache.
/// In a word, this _completerCache provides reusability for completer which is not in 
/// official ImageCache.
final Map<ExternalAdapterImage, ExternalAdapterImageStreamCompleter> _completerCache = 
  <ExternalAdapterImage, ExternalAdapterImageStreamCompleter>{};

/// For image widget, we may first query its image info to get layouy dimensions.
/// We cache some dimension infos for better scrolling experience because we can 
/// quickly get image size from cache without having to query from adapter.
final Map<ExternalAdapterImage, List<int>> _imageInfoCache = <ExternalAdapterImage, List<int>>{};

const int _kImageInfoCacheSize = 200;

List<int> _queryImageInfo(ExternalAdapterImage key) {
  // Remove from the list so that we can move it to the recently used position below.
  final List<int> info = _imageInfoCache.remove(key);
  if (info != null) {
    _imageInfoCache[key] = info;
  }
  return info;
}

void _putImageInfo(ExternalAdapterImage key, List<int> info) {
  _imageInfoCache[key] = info;

  // Check size.
  while (_imageInfoCache.length > _kImageInfoCacheSize) {
    _imageInfoCache.remove(_imageInfoCache.keys.first);
  }
}

/// A completer manages the decoding and scheduling of image frames.
/// This completer supports single frame or multiframe images.
/// This completer also supports any kind of provider as placeholder image provider.
class ExternalAdapterImageStreamCompleter extends ImageStreamCompleter {

  /// Create and ExternalAdapterImageStreamCompleter.
  ExternalAdapterImageStreamCompleter({
    @required ExternalAdapterImage key,
    image_provider.ImageProvider placeholderProvider,
    image_provider.ImageConfiguration configuration,
    InformationCollector informationCollector,
  }) : assert(key != null),
      _key = key, _informationCollector = informationCollector,
      _placeholderProvider = placeholderProvider,
      _configuration = configuration {

    _onlyRequestForDimension = _configuration != null && _configuration.requestForDimension;
    _recreate();
  }

  // Use another list because member in ImageStreamCompleter is private to us.
  final List<ImageStreamListener> _listeners = <ImageStreamListener>[];
  final ExternalAdapterImage _key;
  ui.ExternalAdapterImageFrameCodec _codec;
  bool _codecErrorReported = false;
  bool _isMultiframe = false;
  
  // Provider of placeholder image.
  bool _anyMainFrameEmitted = false;
  final image_provider.ImageConfiguration _configuration;
  final image_provider.ImageProvider _placeholderProvider;
  ImageStream _placeholderStream;

  final InformationCollector _informationCollector;
  
  ui.FrameInfo _nextFrame;

  // Used when this completer only for requesting dimension.
  bool _onlyRequestForDimension;
  List<int> _imageInfo;
  
  Duration _shownTimestamp; // When the current was first shown.
  Duration _frameDuration; // The requested duration for the current frame;
  int _framesEmitted = 0; // How many frames have been emitted so far.
  Timer _timer;

  // Used to guard against registering multiple _handleAppFrame callbacks for the same frame.
  bool _frameCallbackScheduled = false;

  ImageStreamListener _getPlaceholderListener() {
    return ImageStreamListener(
      _handlePlaceholderImageFrame,
      onChunk: null,
      onError: _handlePlaceholderImageError,
    );
  }

  void _finalizePlaceholderStuff() {
    _placeholderStream.removeListener(_getPlaceholderListener()); // Break the retain cycle.
    _placeholderStream = null;
  }
 
  void _handlePlaceholderImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    // On getting placeholder image, we should check if any valid frame is emitted by main provider.
    if (!_anyMainFrameEmitted) {
      setImage(imageInfo);
    }
    _finalizePlaceholderStuff();
  }

  void _handlePlaceholderImageError(dynamic exception, StackTrace stackTrace) {
    _finalizePlaceholderStuff();
  }

  void _loadPlaceholder() {
    if (_placeholderProvider != null &&
        _configuration != null && !_onlyRequestForDimension) {
      /*
      ExternalAdapterImageStreamCompleter owns _placeholderStream
      _placeholderStream owns result of _getPlaceholderListener()
      The listener owns _handlePlaceholderImageFrame and owns ExternalAdapterImageStreamCompleter.
      There is a retain cycle.
       */
      _placeholderStream = _placeholderProvider.resolve(_configuration);
      assert(_placeholderStream != null);
      if (_placeholderStream != null) {
        _placeholderStream.addListener(_getPlaceholderListener());
      }
    }
  }

  void _handleCodecReady(ui.Codec codec) {
    if (codec == null) {
      if (!_codecErrorReported) {
        reportError(
          context: ErrorDescription('Fail to resolve external adapter image codec.'),
          exception: 'Fail to resolve external adapter image codec.',
          stack: StackTrace.current,
          informationCollector: _informationCollector,
          silent: true,
        );
        _codecErrorReported = true;
      }
      return;
    }

    _codec = codec as ui.ExternalAdapterImageFrameCodec;
    if (hasListeners) {
      _decodeNextFrameAndSchedule();
    }
  }

  void _handleAppFrame(Duration timestamp) {
    _frameCallbackScheduled = false;
    if (!hasListeners)
      return;
    if (_isFirstFrame() || _hasFrameDurationPassed(timestamp)) {
      _emitFrame(ImageInfo(image: _nextFrame.image, scale: _key.scale));
      _shownTimestamp = timestamp;
      _frameDuration = _nextFrame.duration;
      _nextFrame = null;
      final int completedCycles = _framesEmitted ~/ _codec.frameCount;
      if (_codec.repetitionCount == -1 || completedCycles <= _codec.repetitionCount) {
        _decodeNextFrameAndSchedule();
      }
      return;
    }
    _timer = Timer(Duration.zero, () {
      _scheduleAppFrame();
    });
  }

  bool _isFirstFrame() {
    return _frameDuration == null;
  }

  bool _hasFrameDurationPassed(Duration timestamp) {
    assert(_shownTimestamp != null);
    return timestamp - _shownTimestamp >= _frameDuration;
  }

  Future<void> _decodeNextFrameAndSchedule() async {
    final ui.ExternalAdapterImageFrameCodec currentCodec = _codec;

    if (_onlyRequestForDimension) {
      if (_imageInfo != null) {
        _emitImageInfo(_imageInfo);
        return;
      }

      List<int> imageInfo = _queryImageInfo(_key);
      if (imageInfo == null) {
        try {
          imageInfo = await currentCodec.getImageInfo();
        } catch (exception, stack) {
          reportError(
            context: ErrorDescription('resolving an image for info'),
            exception: exception,
            stack: stack,
            informationCollector: _informationCollector,
            silent: true,
          );
          return;
        }

        if (currentCodec != _codec) {
          // _codec might be recreated.
          return;
        }
      }

      if (imageInfo != null) {
        _putImageInfo(_key, imageInfo);
        _emitImageInfo(imageInfo);
      }

      return; 
    }

    // Request for image and texture.
    ui.FrameInfo newFrame;
    try {
      newFrame = await currentCodec.getNextFrame();
    } catch (exception, stack) {
      reportError(
        context: ErrorDescription('resolving an image frame'),
        exception: exception,
        stack: stack,
        informationCollector: _informationCollector,
        silent: true,
      );
      return;
    }

    if (currentCodec != _codec) {
      // _codec might be recreated.
      return;
    }

    _nextFrame = newFrame;
    if (_codec.frameCount == 1) {
      // We can also save image info because we even got the image.
      if (_nextFrame.image != null) {
        _putImageInfo(_key, <int>[_nextFrame.image.width, _nextFrame.image.height, 1, 0, -1]);
      }

      // This is not an animated image, just return it and don't schedule more frames.
      _emitFrame(ImageInfo(image: _nextFrame.image, scale: _key.scale));
      return;
    }
    else {
      if (!_isMultiframe && _nextFrame.image != null) {
        // First time enter here.
        _putImageInfo(_key, <int>[_nextFrame.image.width, _nextFrame.image.height, 
          _codec.frameCount, _nextFrame.duration.inMilliseconds * _codec.frameCount, _codec.repetitionCount]);
      }

      _isMultiframe = true;
    }
    _scheduleAppFrame();
  }

  void _scheduleAppFrame() {
    if (_frameCallbackScheduled) {
      return;
    }
    _frameCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_handleAppFrame);
  }

  void _emitImageInfo(List<int> rawInfo) {
    if (rawInfo.length == 5) {
      _imageInfo = rawInfo; // Record the image info.

      if (_listeners.isNotEmpty) {        
        // Make a copy to allow for concurrent modification.
        final List<ImageStreamListener> localListeners =
            List<ImageStreamListener>.from(_listeners);
        for (ImageStreamListener listener in localListeners) {
          try {
            if (listener.onImageInfo != null) {
              listener.onImageInfo(rawInfo[0], rawInfo[1], rawInfo[2], rawInfo[3], rawInfo[4]);
            }
          } catch (exception, stack) {
            reportError(
              context: ErrorDescription('by an image listener'),
              exception: exception,
              stack: stack,
            );
          }
        }
      }
    }
  }

  void _emitFrame(ImageInfo imageInfo) {
    _anyMainFrameEmitted = true;
    setImage(imageInfo);
    _framesEmitted += 1;
  }

  void _reset() {
    // Remove this from _completerCache.
    _completerCache.remove(_key);

    if (_timer != null) {
      _timer.cancel();
      _timer = null;
    }

    // Notify codec to cancel the request.
    if (_codec != null) {
      _codec.cancel();
      _codec = null;
    }

    // Release the frame for saving memory.
    setImage(null);
    _nextFrame = null;
    
    _imageInfo = null;
    _shownTimestamp = null;
    _frameDuration = null;
    _framesEmitted = 0;
    _anyMainFrameEmitted = false;
    _frameCallbackScheduled = false;
    _isMultiframe = false;
  }

  void _recreate() {
    _loadPlaceholder();
    _handleCodecReady(_key._loadCodec());
  }
 
  @override
  void addListener(ImageStreamListener listener) {
    // We must add to _listeners first. Because super.addListener may invoke onImage which may eventually invoke removeListener.
    final bool previouslyEmptyListeners = !hasListeners;

    if (previouslyEmptyListeners) {
      // Add the first listener to this completer.
      _completerCache[_key] = this;
    }

    _listeners.add(listener);
    super.addListener(listener);

    if (_onlyRequestForDimension && _imageInfo != null) {
      // This completer is only used for fetching image dimension. We callback new listener.
      try {
        if (listener.onImageInfo != null) {
          listener.onImageInfo(_imageInfo[0], _imageInfo[1], _imageInfo[2], _imageInfo[3], _imageInfo[4]);
        }
      } catch (exception, stack) {
        reportError(
          context: ErrorDescription('by an image listener'),
          exception: exception,
          stack: stack,
        );
      }      
      return;
    }

    if (!_isMultiframe && _anyMainFrameEmitted) {
      return;
    }

    // Any listeners added, but the _codec migth be freed previously. We recreate the codec.
    if (_codec == null) {
      _recreate();
      return;
    }

    if (previouslyEmptyListeners && _codec != null)
      _decodeNextFrameAndSchedule();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);

    for (int i = 0; i < _listeners.length; i += 1) {
      if (_listeners[i] == listener) {
        _listeners.removeAt(i);
        break;
      }
    }

    if (_listeners.isEmpty) {
      _reset();
    }
  }
}

/// The dart:io implementation of [image_provider.ExternalAdapterImage].
class ExternalAdapterImage extends image_provider.ImageProvider<image_provider.ExternalAdapterImage> implements image_provider.ExternalAdapterImage {
  
  /// Create an ExternalAdapterImage.
  ExternalAdapterImage(
    this.url,
    {
      this.scale,
      this.targetWidth,
      this.targetHeight,
      this.placeholderProvider,
      this.parameters,
      this.extraInfo,
      this.releaseWhenOutOfScreen = false,
    }
  )
  : assert(url != null);

  @override
  final String url;

  @override
  final double scale;

  @override
  final int targetWidth;

  @override
  final int targetHeight;

  @override
  final image_provider.ImageProvider placeholderProvider;

  @override
  final Map<String, String> parameters;

  @override
  final Map<String, String> extraInfo;

  @override
  final bool releaseWhenOutOfScreen;

  @override
  image_provider.ImageConfiguration imageConfiguration;

  ExternalAdapterImage _copy() {
    return ExternalAdapterImage(url, scale: scale, targetWidth: targetWidth, 
      targetHeight: targetHeight, placeholderProvider: placeholderProvider, 
      parameters: parameters, extraInfo: extraInfo);
  }

  @override
  Future<ExternalAdapterImage> obtainKey(image_provider.ImageConfiguration configuration) {
    final ExternalAdapterImage provider = _copy();
    provider.imageConfiguration = configuration;
    return SynchronousFuture<ExternalAdapterImage>(provider);
  }

  @override
  ImageStreamCompleter load(image_provider.ExternalAdapterImage key, image_provider.DecoderCallback decode) {
    final ExternalAdapterImageStreamCompleter cached = _completerCache[key];
    if (cached != null) {
      return cached;
    }
    
    return ExternalAdapterImageStreamCompleter(
      key: key,
      placeholderProvider: key.placeholderProvider,
      configuration: key.imageConfiguration,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<image_provider.ImageProvider>('Image provider', key),
          DiagnosticsProperty<image_provider.ExternalAdapterImage>('Image key', key),
        ];
      },
    );
  }

  ui.Codec _loadCodec() {
    return ui.ExternalAdapterInstantiateImageCodec(
      url,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      parameters: parameters,
      extraInfo: extraInfo
    );
  }

  bool _mapsEqual(Map<String, String> m1, Map<String, String> m2) {
    if (m1 == null) {
      if (m2 == null) {
        return true;
      }
      else if (m2.isEmpty) {
        return true;
      }
      else {
        return false;
      }
    }
    else if (m2 == null) {
      if (m1.isEmpty) {
        return true;
      }
      else {
        return false;
      }
    }

    if (m1.keys.length != m2.keys.length) 
      return false;
    for (dynamic o in m1.keys) {
      if (!m2.keys.contains(o)) 
        return false;
      if (m1[o] != m2[o]) 
        return false;
    }
    return true;
  }

  bool _configurationsEqual(image_provider.ImageConfiguration c1, image_provider.ImageConfiguration c2) {
    // We cannot use the same completer if one is only for requesting dimension. 
    if (c1 == null) {
      return c2 == null;
    }
    else if (c2 != null) {
      return c1.requestForDimension == c2.requestForDimension;
    }
    else {
      return false;
    }
  }

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType)
      return false;
    final ExternalAdapterImage typedOther = other;
    return url == typedOther.url
      && scale == typedOther.scale
      && targetWidth == typedOther.targetWidth
      && targetHeight == typedOther.targetHeight
      && placeholderProvider == typedOther.placeholderProvider
      && _mapsEqual(parameters, typedOther.parameters)
      && _configurationsEqual(imageConfiguration, typedOther.imageConfiguration);
  }

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '$runtimeType("$url", scale: $scale, '
      'target-size: $targetWidth * $targetHeight, '
      'params: $parameters, '
      'requestForDimension: ${imageConfiguration?.requestForDimension})';
}

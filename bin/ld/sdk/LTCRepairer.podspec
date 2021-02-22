#
# NOTE: This podspec is NOT to be published. It is only used as a local source!
#

Pod::Spec.new do |s|
  s.name             = 'LTCRepairer'
  s.version          = '1.0.0'
  s.summary          = 'LTCRepairer is helper dynamic library which will be first loaded.'
  s.description      = <<-DESC
LTCRepairer is helper dynamic library which will be first loaded. It will invoke decompress method. It is recommended to link LTCRepairer for all Apps using ldiff linker to compress main image.
                       DESC
  s.homepage         = 'https://yuque.antfin.com/qianyuan.wqy/dsxix1/swq190'
  s.license          = { :type => 'MIT' }
  s.author           = { 'shenmo' => 'qianyuan.wqy@alibaba-inc.com' }
  s.source           = { :git => 'https://', :tag => s.version.to_s }
  s.ios.deployment_target = '8.0'
  s.vendored_frameworks = 'LTCRepairer.framework'
end

#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint easyconn_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'easyconn_core'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.subspec 'EasyConnKit' do |ss|
    ss.source_files = 'easyconn_core/EasyConnKit/Sources/EasyConnKit/**/*'
  end

  s.subspec 'Core' do |ss|
    ss.source_files = 'easyconn_core/Sources/easyconn_core/**/*'
    ss.dependency 'easyconn_core/EasyConnKit'
  end
end

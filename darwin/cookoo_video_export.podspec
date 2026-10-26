#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cookoo_video_export.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cookoo_video_export'
  s.version          = '0.1.0'
  s.summary          = 'Deterministic native video encoding and audio muxing.'
  s.description      = <<-DESC
Deterministic native video encoding and audio muxing.
                       DESC
  s.homepage         = 'https://github.com/cookoocode/cookoo_video_export'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'COOKOO'
  s.source           = { :path => '.' }
  s.source_files = 'cookoo_video_export/Sources/cookoo_video_export/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'cookoo_video_export_privacy' => ['cookoo_video_export/Sources/cookoo_video_export/PrivacyInfo.xcprivacy']}
end

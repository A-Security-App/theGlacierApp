# Disable CocoaPods deterministic UUIDs as Pods are not checked in
ENV["COCOAPODS_DISABLE_DETERMINISTIC_UUIDS"] = "true"

# Disable Bitcode for all targets http://stackoverflow.com/a/32685434/805882
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['CLANG_WARN_DOCUMENTATION_COMMENTS'] = 'NO'
      config.build_settings['CLANG_WARN_STRICT_PROTOTYPES'] = 'NO'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    end
  end
end

platform :ios, "18.0"

use_frameworks!
# inhibit_all_warnings!

source 'https://github.com/CocoaPods/Specs.git'

abstract_target 'GlacierPods' do

  target 'Glacier' do
    pod 'SQLCipher', '~> 4.10.0'
    pod 'GRDB.swift/SQLCipher'
    pod 'SAMKeychain', :git => 'https://github.com/afriedmanGlacier/SAMKeychain.git'
    pod 'Kingfisher', '~> 7.12.0'

    pod 'TwilioVoice', '~> 6.12.0'
    # Pinned to 1.9.11 (the last BSD-2-Clause release). Versions 2.0.0+ are
    # relicensed under a proprietary SecuRing EULA that forbids charging fees
    # for a program that includes the Software except under the paid Enterprise
    # plan — incompatible with our subscription app. Do NOT bump to 2.x without
    # a licensing decision. All APIs we use exist in 1.9.11.
    pod 'IOSSecuritySuite', '1.9.11'
    pod 'JWTDecode', '~> 3.3'
    pod 'Alamofire', '~> 5.9.1'
    pod 'MBProgressHUD', '~> 1.2'
    pod 'BBlock', '~> 1.2.1'

    target 'GlacierTests' do
      inherit! :search_paths
    end

  end
end



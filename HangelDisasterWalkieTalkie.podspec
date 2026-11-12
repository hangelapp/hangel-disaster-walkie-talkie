require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'HangelDisasterWalkieTalkie'
  s.version = package['version']
  s.summary = 'Offline disaster walkie-talkie (Bluetooth LE / peer-to-peer Wi-Fi mesh) for Capacitor apps.'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.homepage = package['homepage']
  s.author = package['author']
  s.source = { :git => 'https://github.com/hangelapp/hangel-disaster-walkie-talkie.git', :tag => s.version.to_s }
  s.source_files = 'ios/Sources/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.dependency 'Capacitor'
  s.swift_version = '5.9'
  s.module_name = 'DisasterWalkieTalkiePlugin'
end

Pod::Spec.new do |s|
  s.name             = 'slide_native'
  s.version          = '1.0.0'
  s.summary          = 'Código nativo de Slide Remote: BLE periférico y botones de volumen.'
  s.description      = 'Anuncia un servicio Bluetooth LE para la app de escritorio y captura los botones de volumen.'
  s.homepage         = 'https://github.com/l-gonzo'
  s.license          = { :type => 'MIT' }
  s.author           = { 'l-gonzo' => 'l-gonzo@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'CoreBluetooth', 'AVFoundation', 'MediaPlayer'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end

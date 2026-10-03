Pod::Spec.new do |s|
  s.name           = 'LensiAR'
  s.version        = '1.0.0'
  s.summary        = 'ARKit + on-device Vision camera view for Lensi'
  s.description    = 'Tracks objects with YOLO on the Neural Engine, segments the tapped subject and pins annotations in world space.'
  s.author         = ''
  s.homepage       = 'https://github.com/vedantlbhatt/lensi'
  s.platforms      = { :ios => '17.0' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.swift_version = '5.9'
  s.frameworks = 'ARKit', 'SceneKit', 'Vision', 'CoreML', 'AVFoundation', 'Speech', 'CoreImage', 'ImageIO'
  # Apple Intelligence is iOS 26+; weak-link so the app still launches on 17-25.
  s.weak_frameworks = 'FoundationModels'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift}"
  s.resource_bundles = { 'LensiARModels' => ['Models/*.mlmodelc'] }
end

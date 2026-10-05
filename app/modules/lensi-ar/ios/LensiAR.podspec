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
    # Everything that follows a thing runs every frame in plain Swift: the flow's Lucas-Kanade,
    # the outlines' math, EdgeTAM's memory and masks. Unoptimised, as a Debug build (`expo run:ios`)
    # compiles it, that runs many times slower than what CI measures, and on a phone the outlines
    # lag and jump. Optimised in every configuration.
    'SWIFT_OPTIMIZATION_LEVEL' => '-O',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
  }

  s.source_files = "**/*.{h,m,mm,swift}"
  s.resource_bundles = { 'LensiARModels' => ['Models/*.mlmodelc'] }
end

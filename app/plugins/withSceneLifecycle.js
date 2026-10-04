// iOS 27 refuses to launch an app built with its SDK unless the app adopts the
// UIScene life cycle ("Application failed to launch: UIScene life cycle is
// required for apps built with this SDK"). Expo SDK 57 ships the pieces
// (ExpoAppSceneDelegate, ExpoReactNativeFactoryProvider) but its prebuild
// template still starts React Native from the app delegate, so this plugin:
//
//  - declares a scene manifest whose delegate is SceneDelegate, a subclass of
//    ExpoAppSceneDelegate living in the app target;
//  - makes AppDelegate an ExpoReactNativeFactoryProvider (it already owns the
//    factory and the window property);
//  - stops AppDelegate creating a window of its own: the scene delegate makes
//    it from the connecting UIWindowScene and starts React Native in it.
//
// Every edit is checked, so a template change fails prebuild loudly instead of
// shipping an app that dies at launch.
const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

const SCENE_DELEGATE = '$(PRODUCT_MODULE_NAME).SceneDelegate';

function withSceneLifecycle(config) {
  config = withInfoPlist(config, (c) => {
    c.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [
          { UISceneConfigurationName: 'Default Configuration', UISceneDelegateClassName: SCENE_DELEGATE },
        ],
      },
    };
    return c;
  });

  config = withAppDelegate(config, (c) => {
    if (c.modResults.language !== 'swift') {
      throw new Error('withSceneLifecycle: expected a Swift AppDelegate');
    }
    let src = c.modResults.contents;
    if (src.includes('class SceneDelegate: ExpoAppSceneDelegate')) return c;

    const edit = (re, to, what) => {
      const next = src.replace(re, to);
      if (next === src) throw new Error(`withSceneLifecycle: could not ${what}; the AppDelegate template changed`);
      src = next;
    };
    edit(
      /class AppDelegate: ExpoAppDelegate \{/,
      'class AppDelegate: ExpoAppDelegate, ExpoReactNativeFactoryProvider {',
      'make AppDelegate a factory provider',
    );
    edit(
      /#if os\(iOS\) \|\| os\(tvOS\)\s*\n\s*window = UIWindow\(frame: UIScreen\.main\.bounds\)\s*\n\s*factory\.startReactNative\([\s\S]*?\)\s*\n#endif\s*\n/,
      '    // The window and React Native start in SceneDelegate (UIScene life cycle).\n',
      'move window creation to the scene delegate',
    );
    src += `
// iOS 27 needs the UIScene life cycle. Expo's scene delegate creates the window
// from the connecting scene and starts React Native with the factory above.
class SceneDelegate: ExpoAppSceneDelegate {}
`;
    c.modResults.contents = src;
    return c;
  });

  return config;
}

module.exports = withSceneLifecycle;

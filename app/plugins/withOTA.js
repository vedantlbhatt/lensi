// Over the air (src/lib/ota.ts, tools/ota): JavaScript published since a build, for the same
// native code, runs instead of the bundle built in, so a JavaScript change reaches an
// installed iPhone without a new install.
//
//  - The Info.plist gets LensiRuntime: tools/ota/runtime.py, a hash of everything that goes
//    into the native build. Updates are published per runtime, and the app only takes its own.
//  - AppDelegate starts from Documents/ota/current/main.jsbundle when an update for this
//    runtime is there. A launch from it leaves a mark that the JavaScript clears once it's
//    running; a mark an earlier launch left means that launch never got going, so the update
//    is set aside and the built-in bundle runs. React Native asks for the bundle more than
//    once in a launch (and again on a reload), so the mark says which launch left it: CI's
//    Simulator run caught every cold start setting its own update aside.
//
// Every edit is checked, so a template change fails prebuild loudly.
const { execFileSync } = require('child_process');
const path = require('path');
const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

const LOADER = `

/// This launch, as the over-the-air mark records it (one per process).
let lensiLaunch = UUID().uuidString

/// Over the air (plugins/withOTA.js): the JavaScript published since this build for the same
/// native code, in Documents/ota/current (main.jsbundle, its assets, update.json), or nil for
/// the bundle built in. React Native asks more than once in a launch, and again on a reload:
/// the same answer each time, and only a mark an earlier launch left counts against it.
func lensiUpdateBundleURL() -> URL? {
  let fm = FileManager.default
  guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
  let ota = docs.appendingPathComponent("ota", isDirectory: true)
  let current = ota.appendingPathComponent("current", isDirectory: true)
  let bundle = current.appendingPathComponent("main.jsbundle")
  let mark = ota.appendingPathComponent("launching")
  guard fm.fileExists(atPath: bundle.path) else { return nil }
  var update: [String: Any] = [:]
  if let data = try? Data(contentsOf: current.appendingPathComponent("update.json")),
     let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    update = json
  }
  let runtime = update["runtime"] as? String
  let mine = Bundle.main.object(forInfoDictionaryKey: "LensiRuntime") as? String
  // Whose mark: none, this launch's (asked again), or an earlier launch's that never got going.
  let marked: String? = fm.fileExists(atPath: mark.path) ? ((try? String(contentsOf: mark, encoding: .utf8)) ?? "") : nil
  if (marked != nil && marked != lensiLaunch) || mine == nil || runtime != mine {
    // The last launch from it never got going, or it's for other native code: set it aside
    // (the JavaScript won't fetch the same one again) and start from the built-in bundle.
    let failed = ota.appendingPathComponent("failed", isDirectory: true)
    try? fm.removeItem(at: failed)
    try? fm.moveItem(at: current, to: failed)
    try? fm.removeItem(at: mark)
    NSLog("[lensi] over the air: set aside the update in %@ (%@)", current.path,
          marked != nil ? "an earlier launch from it never got going" : "it's for other native code")
    return nil
  }
  if marked == nil {
    try? lensiLaunch.write(to: mark, atomically: true, encoding: .utf8)
    NSLog("[lensi] over the air: starting from update %@", String(describing: update["id"] ?? "?"))
  }
  return bundle
}
`;

function runtime(projectRoot) {
  try {
    return execFileSync('python3', [path.join(projectRoot, '..', 'tools', 'ota', 'runtime.py')], { encoding: 'utf8' }).trim() || 'none';
  } catch {
    return 'none';
  }
}

function withOTA(config) {
  config = withInfoPlist(config, (c) => {
    c.modResults.LensiRuntime = runtime(c.modRequest.projectRoot);
    return c;
  });
  config = withAppDelegate(config, (c) => {
    if (c.modResults.language !== 'swift') throw new Error('withOTA: expected a Swift AppDelegate');
    let src = c.modResults.contents;
    if (src.includes('func lensiUpdateBundleURL()')) return c;
    const builtIn = 'return Bundle.main.url(forResource: "main", withExtension: "jsbundle")';
    if (!src.includes(builtIn)) throw new Error('withOTA: could not find where the built-in bundle is chosen; the AppDelegate template changed');
    src = src.replace(builtIn, 'return lensiUpdateBundleURL() ?? Bundle.main.url(forResource: "main", withExtension: "jsbundle")');
    c.modResults.contents = src + LOADER;
    return c;
  });
  return config;
}

module.exports = withOTA;

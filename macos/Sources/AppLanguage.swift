import Foundation

// Resolve explicitly so runtime language changes also cover dynamic labels and tooltips.
func L(_ key: String) -> String {
    let language = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
    guard language == "en", let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
          let bundle = Bundle(path: path) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

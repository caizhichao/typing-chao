import Carbon
import Foundation

// 负责把已安装输入法包注册到系统来源，并将启用、选择、卸载保持为彼此独立的动作。
enum InputSourceRegistration {
    static let rootInputSourceID = "com.caizhichao.typingchao.inputmethod.TypingChao"
    static let inputSourceID = "com.caizhichao.typingchao.inputmethod.TypingChao.Pinyin"

    // 进程级监听只在本输入模式当前被选中时读取剪贴板，切换其它输入法后立即停止消费新内容。
    static var isSelected: Bool {
        currentKeyboardInputSourceID == inputSourceID
    }

    static var currentKeyboardInputSourceID: String {
        let currentInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringValue(of: currentInputSource, key: kTISPropertyInputSourceID) ?? "<未知输入源>"
    }

    // 仅注册当前输入法包，供系统级安装阶段调用，不改动用户当前选中的输入法。
    static func register() -> OSStatus {
        TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    }

    // 输出当前用户视角的输入源状态，便于核验注册、启用与选择是否分别生效。
    static func statusDescription() -> String {
        let currentInputSourceID = currentKeyboardInputSourceID
        guard let inputSource = findInputSource(sourceIdentifier: inputSourceID) else {
            return "未在 TIS 输入源列表找到 \(inputSourceID)。\n当前键盘输入源：\(currentInputSourceID)\n当前选中：\(currentInputSourceID == inputSourceID)"
        }
        let rootInputSource = findInputSource(sourceIdentifier: rootInputSourceID)
        let productDisplayName = rootInputSource.flatMap {
            stringValue(of: $0, key: kTISPropertyLocalizedName)
        } ?? "<无产品显示名>"
        let localizedName = stringValue(of: inputSource, key: kTISPropertyLocalizedName) ?? "<无本地化名称>"
        let bundleID = stringValue(of: inputSource, key: kTISPropertyBundleID) ?? "<无 Bundle ID>"
        let enabled = boolValue(of: inputSource, key: kTISPropertyInputSourceIsEnabled)
        let selectable = boolValue(of: inputSource, key: kTISPropertyInputSourceIsSelectCapable)
        return "输入法：\(productDisplayName)\n输入源：\(localizedName)\nBundle ID：\(bundleID)\n已启用：\(enabled)\n可选择：\(selectable)\n当前键盘输入源：\(currentInputSourceID)\n当前选中：\(currentInputSourceID == inputSourceID)"
    }

    private static func findInputSource(sourceIdentifier: String) -> TISInputSource? {
        let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as NSArray
        for case let inputSource as TISInputSource in sourceList {
            guard stringValue(of: inputSource, key: kTISPropertyInputSourceID) == sourceIdentifier else {
                continue
            }
            return inputSource
        }
        return nil
    }

    private static func stringValue(of inputSource: TISInputSource, key: CFString) -> String? {
        guard let property = TISGetInputSourceProperty(inputSource, key) else {
            return nil
        }
        return Unmanaged<AnyObject>.fromOpaque(property).takeUnretainedValue() as? String
    }

    private static func boolValue(of inputSource: TISInputSource, key: CFString) -> Bool {
        guard let property = TISGetInputSourceProperty(inputSource, key),
              let value = Unmanaged<AnyObject>.fromOpaque(property).takeUnretainedValue() as? NSNumber else {
            return false
        }
        return value.boolValue
    }
}

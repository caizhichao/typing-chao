import AppKit
import InputMethodKit

if CommandLine.arguments.contains("--register-input-source") {
    let registrationStatus = InputSourceRegistration.register()
    if registrationStatus == noErr {
        print("已注册 Typing 东南亚输入法包，尚未切换当前输入法。")
    } else {
        print("注册 Typing 东南亚输入法失败，状态码：\(registrationStatus)")
    }
    exit(Int32(registrationStatus))
}

if CommandLine.arguments.contains("--input-source-status") {
    print(InputSourceRegistration.statusDescription())
    exit(0)
}

// 通过 Info.plist 的输入法元数据创建服务，确保系统输入法列表与运行时加载规则一致。
let server = IMKServer(
    name: "TypingDongnanya_1_0",
    bundleIdentifier: Bundle.main.bundleIdentifier
)

NSApplication.shared.run()

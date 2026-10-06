import Foundation

// 3 October 2026, 21:55 CEST: verify actual input selection and unchanged output without capturing audio.
@main struct VerifyBuiltinMicrophone {
    static func main() throws {
        let input=BuiltinMicrophone.shared
        // 6 October 2026, 12:44 CEST: verify startup and capture hooks preserve the selected system input.
        let inputBefore=try input.currentInput()
        let outputBefore=try input.currentOutput()
        try input.start()
        defer { input.stop() }
        try input.pin()
        let expected=inputBefore,actual=try input.currentInput(),outputAfter=try input.currentOutput()
        guard expected==actual,outputBefore==outputAfter else { fatalError("System input or output preservation failed") }
        let proof:[String:Any] = ["date":"6 October 2026","input":try input.name(actual),"inputID":actual,"previousInputID":expected,"output":try input.name(outputAfter),"outputUnchanged":outputBefore==outputAfter]
        print(String(data:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),encoding:.utf8)!)
    }
}

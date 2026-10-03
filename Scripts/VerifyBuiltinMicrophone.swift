import Foundation

// 3 October 2026, 21:55 CEST: verify actual input selection and unchanged output without capturing audio.
@main struct VerifyBuiltinMicrophone {
    static func main() throws {
        let input=BuiltinMicrophone.shared
        let outputBefore=try input.currentOutput()
        try input.start()
        defer { input.stop() }
        let expected=try input.builtInDevice(),actual=try input.currentInput(),outputAfter=try input.currentOutput()
        guard expected==actual,outputBefore==outputAfter else { fatalError("Input pin or output preservation failed") }
        let proof:[String:Any] = ["date":"3 October 2026","input":try input.name(actual),"inputID":actual,"builtinID":expected,"output":try input.name(outputAfter),"outputUnchanged":outputBefore==outputAfter]
        print(String(data:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),encoding:.utf8)!)
    }
}

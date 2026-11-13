import Foundation
import NaturalLanguage
// stdin: JSON array of strings; stdout: JSON array of [code, confidence]
let data = FileHandle.standardInput.readDataToEndOfFile()
let texts = try JSONDecoder().decode([String].self, from: data)
var out: [[String]] = []
for t in texts {
    let r = NLLanguageRecognizer()
    r.processString(t)
    if let top = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }) {
        out.append([top.key.rawValue, String(top.value)])
    } else { out.append(["", "0"]) }
}
print(String(data: try JSONEncoder().encode(out), encoding: .utf8)!)

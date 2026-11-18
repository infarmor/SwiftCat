import Foundation
import SwiftUI

public struct DiffLine: Identifiable, Sendable {
    public let id = UUID()
    public enum Kind: Sendable {
        case same
        case added
        case removed
    }
    public let kind: Kind
    public let text: String
    public let oldLineNum: Int?
    public let newLineNum: Int?
}

public struct DiffEngine {
    public static func computeDiff(oldText: String, newText: String) -> [DiffLine] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        
        let n = oldLines.count
        let m = newLines.count
        
        // 1. Trim identical prefix lines
        var prefixCount = 0
        while prefixCount < n && prefixCount < m && oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }
        
        // 2. Trim identical suffix lines
        var suffixCount = 0
        while suffixCount < (n - prefixCount) && suffixCount < (m - prefixCount)
                && oldLines[n - 1 - suffixCount] == newLines[m - 1 - suffixCount] {
            suffixCount += 1
        }
        
        var result: [DiffLine] = []
        result.reserveCapacity(max(n, m))
        
        for idx in 0..<prefixCount {
            result.append(DiffLine(kind: .same, text: oldLines[idx], oldLineNum: idx + 1, newLineNum: idx + 1))
        }
        
        let midOld = Array(oldLines[prefixCount..<(n - suffixCount)])
        let midNew = Array(newLines[prefixCount..<(m - suffixCount)])
        let midN = midOld.count
        let midM = midNew.count
        
        if midN == 0 {
            for (idx, line) in midNew.enumerated() {
                result.append(DiffLine(kind: .added, text: line, oldLineNum: nil, newLineNum: prefixCount + idx + 1))
            }
        } else if midM == 0 {
            for (idx, line) in midOld.enumerated() {
                result.append(DiffLine(kind: .removed, text: line, oldLineNum: prefixCount + idx + 1, newLineNum: nil))
            }
        } else if midN > 1500 || midM > 1500 {
            // Safety cap when the changed middle region itself is huge
            for (idx, line) in midOld.enumerated() {
                result.append(DiffLine(kind: .removed, text: line, oldLineNum: prefixCount + idx + 1, newLineNum: nil))
            }
            for (idx, line) in midNew.enumerated() {
                result.append(DiffLine(kind: .added, text: line, oldLineNum: nil, newLineNum: prefixCount + idx + 1))
            }
        } else {
            // Flat contiguous DP LCS matrix on the changed slice only (single allocation)
            let cols = midM + 1
            var dp = Array(repeating: 0, count: (midN + 1) * cols)
            for i in 0..<midN {
                let rowOffset = i * cols
                let nextRowOffset = (i + 1) * cols
                for j in 0..<midM {
                    if midOld[i] == midNew[j] {
                        dp[nextRowOffset + j + 1] = dp[rowOffset + j] + 1
                    } else {
                        dp[nextRowOffset + j + 1] = max(dp[nextRowOffset + j], dp[rowOffset + j + 1])
                    }
                }
            }
            
            var i = midN
            var j = midM
            var reverseDiff: [(DiffLine.Kind, String, Int?, Int?)] = []
            
            while i > 0 || j > 0 {
                if i > 0 && j > 0 && midOld[i - 1] == midNew[j - 1] {
                    reverseDiff.append((.same, midOld[i - 1], prefixCount + i, prefixCount + j))
                    i -= 1
                    j -= 1
                } else if j > 0 && (i == 0 || dp[i * cols + (j - 1)] >= dp[(i - 1) * cols + j]) {
                    reverseDiff.append((.added, midNew[j - 1], nil, prefixCount + j))
                    j -= 1
                } else if i > 0 && (j == 0 || dp[i * cols + (j - 1)] < dp[(i - 1) * cols + j]) {
                    reverseDiff.append((.removed, midOld[i - 1], prefixCount + i, nil))
                    i -= 1
                }
            }
            
            for item in reverseDiff.reversed() {
                result.append(DiffLine(kind: item.0, text: item.1, oldLineNum: item.2, newLineNum: item.3))
            }
        }
        
        for idx in 0..<suffixCount {
            let oldIdx = n - suffixCount + idx
            let newIdx = m - suffixCount + idx
            result.append(DiffLine(kind: .same, text: oldLines[oldIdx], oldLineNum: oldIdx + 1, newLineNum: newIdx + 1))
        }
        
        return result
    }
}

//
//  CIEANBarcodeGenerator.swift
//  BarcodeCreator
//
//  Created by David Vittori on 22/08/21.
//  Copyright © 2021 Facebook. All rights reserved.
//

import Foundation
import CoreImage
import UIKit

@objcMembers
public class CIEANBarcodeGeneratorConstructor: CIFilterConstructor {
    public func filter(withName name: String) -> CIFilter? {
        return CIEANBarcodeGenerator()
    }
}

@objcMembers
public class CIEANBarcodeGenerator: CIFilter {

    private static let kernelSrc =
        "kernel vec4 coreImageKernel(float barCount, vec4 vector) {\n" +
        "    vec2 dc = destCoord();\n" +
        "    int x = int(floor(dc.x));\n" +
        "    int y = int(floor(dc.y));\n" +
        "    if (x < 0 || x >= int(barCount) || y < 0 || y >= 32) {\n" +
        "        return vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "    }\n" +
        "    int vectorIndex = int(x / 24);\n" +
        "    int value = int(vector[vectorIndex]);\n" +
        "    value = value & (1 << (x % 24));\n" +
        "    if (value != 0) {\n" +
        "       return vec4(0.0, 0.0, 0.0, 1.0);\n" +
        "    }\n" +
        "    return vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "}\n"

    // codingMap: [left, right, guard(G)]
    private static let codingMap: [[UInt8]] = [
        [0b0001101, 0b1110010, 0b0100111], // 0
        [0b0011001, 0b1100110, 0b0110011], // 1
        [0b0010011, 0b1101100, 0b0011011], // 2
        [0b0111101, 0b1000010, 0b0100001], // 3
        [0b0100011, 0b1011100, 0b0011101], // 4
        [0b0110001, 0b1001110, 0b0111001], // 5
        [0b0101111, 0b1010000, 0b0000101], // 6
        [0b0111011, 0b1000100, 0b0010001], // 7
        [0b0110111, 0b1001000, 0b0001001], // 8
        [0b0001011, 0b1110100, 0b0010111]  // 9
    ]

    // EAN-13 left-part parity map
    private static let leftPartMap: [UInt8] = [
        0b000000, // 0
        0b001011, // 1
        0b001101, // 2
        0b001110, // 3
        0b010011, // 4
        0b011001, // 5
        0b011100, // 6
        0b010101, // 7
        0b010110, // 8
        0b011010  // 9
    ]

    // UPC-E parity table for number system 0 (0 = L, 1 = G); number system 1 inverts parity
    private static let upceParityTable: [[UInt8]] = [
        [0,0,0,0,0,0], // check 0
        [0,0,1,0,1,1], // 1
        [0,0,1,1,0,1], // 2
        [0,0,1,1,1,0], // 3
        [0,1,0,0,1,1], // 4
        [0,1,1,0,0,1], // 5
        [0,1,1,1,0,0], // 6
        [0,1,0,1,0,1], // 7
        [0,1,0,1,1,0], // 8
        [0,1,1,0,1,0]  // 9
    ]

    @objc
    private var inputMessage: Data = Data()

    public override var attributes: [String : Any] {
        return [
            "inputMessage": [
                kCIAttributeName: "inputMessage",
                kCIAttributeDisplayName: "inputMessage",
                kCIAttributeClass: "NSData",
                kCIAttributeDefault: ""
            ]
        ]
    }

    public class func register() {
        CIFilter.registerName("CIEANBarcodeGenerator",
                              constructor: CIEANBarcodeGeneratorConstructor(),
                              classAttributes: [
                                kCIAttributeFilterDisplayName: "EAN/UPC barcode generator",
                                kCIAttributeFilterCategories: [kCICategoryBuiltIn]
            ]
        )
    }

    public override var outputImage: CIImage? {
        get {
            return drawOutputImage()
        }
    }

    public override func setDefaults() {
        inputMessage = Data()
    }

    private func drawOutputImage() -> CIImage? {
        guard let barcodeData: Data = value(forKey: "inputMessage") as? Data else {
            print("Invalid barcode data")
            return nil
        }
        let barcode = parseBarcodeString(barcodeData)
        if validateEAN13Barcode(barcode) {
            return drawEAN13(barcode: barcode)
        } else if validateUPCABarcode(barcode) {
            return drawUPCA(barcode: barcode)
        } else if validateEAN8Barcode(barcode) {
            return drawEAN8(barcode: barcode)
        } else if validateUPCEBarcode(barcode) {
            return drawUPCE(barcode: barcode)
        } else {
            print("Invalid barcode. Supported: EAN-13, UPC-A, EAN-8, UPC-E")
            return nil
        }
    }

    private func parseBarcodeString(_ barcodeData: Data) -> [UInt8] {
        let str = String(decoding: barcodeData, as: UTF8.self)
        let intArray = str.compactMap { UInt8(String($0)) }
        return intArray
    }

    // MARK: - Drawing specific symbologies

    private func drawEAN13(barcode: [UInt8]) -> CIImage? {
        let firstNumber = Int(barcode.first!)
        let leftPartPattern = CIEANBarcodeGenerator.leftPartMap[firstNumber]
        let leftPart = [UInt8](barcode[1...6])
        let rightPart = [UInt8](barcode[7...12])
        let bars = prepareBars(leftPart: leftPart,
                               rightPart: rightPart,
                               leftPartPattern: leftPartPattern)
        return drawBarcode(bars: bars)
    }

    private func drawUPCA(barcode: [UInt8]) -> CIImage? {
        // UPC-A acts like EAN-13 with implicit leading 0 parity pattern 000000
        let leftPartPattern = CIEANBarcodeGenerator.leftPartMap.first!
        let leftPart = [UInt8](barcode[0...5])
        let rightPart = [UInt8](barcode[6...11])
        let bars = prepareBars(leftPart: leftPart,
                               rightPart: rightPart,
                               leftPartPattern: leftPartPattern)
        return drawBarcode(bars: bars)
    }

    private func drawEAN8(barcode: [UInt8]) -> CIImage? {
        let leftPart = Array(barcode[0...3])
        let rightPart = Array(barcode[4...7])
        var bars: [UInt8] = [1,0,1] // start
        for d in leftPart {
            bars.append(contentsOf: toBitArray(CIEANBarcodeGenerator.codingMap[Int(d)][0]))
        }
        bars.append(contentsOf: [0,1,0,1,0]) // middle
        for d in rightPart {
            bars.append(contentsOf: toBitArray(CIEANBarcodeGenerator.codingMap[Int(d)][1]))
        }
        bars.append(contentsOf: [1,0,1]) // end
        return drawBarcode(bars: bars)
    }

    private func drawUPCE(barcode: [UInt8]) -> CIImage? {
        let numberSystem = barcode[0]
        let dataDigits = Array(barcode[1...6]) // 6 data digits
        let checkDigit = barcode[7]
        let parityRowBase = CIEANBarcodeGenerator.upceParityTable[Int(checkDigit)]
        var bars: [UInt8] = [1,0,1] // start guard 101
        for i in 0..<6 {
            let digit = Int(dataDigits[i])
            // Adjust parity for number system 1 (invert)
            let parity = numberSystem == 1 ? (parityRowBase[i] == 0 ? 1 : 0) : parityRowBase[i]
            // 0 -> L (left), 1 -> G (guard)
            let patternValue: UInt8 = (parity == 0)
                ? CIEANBarcodeGenerator.codingMap[digit][0]
                : CIEANBarcodeGenerator.codingMap[digit][2]
            bars.append(contentsOf: toBitArray(patternValue))
        }
        // UPC-E end pattern 010101
        bars.append(contentsOf: [0,1,0,1,0,1])
        return drawBarcode(bars: bars)
    }

    // Shared builder for EAN-13 / UPC-A
    private func prepareBars(leftPart: [UInt8],
                             rightPart: [UInt8],
                             leftPartPattern: UInt8) -> [UInt8] {
        var bars: [UInt8] = []
        bars.append(contentsOf: [1, 0, 1]) // start
        for i in 0..<leftPart.count {
            let n = Int(leftPart[i])
            let value: UInt8
            if leftPartPattern & (1 << (leftPart.count - 1 - i)) == 0 {
                value = CIEANBarcodeGenerator.codingMap[n][0] // left (L)
            } else {
                value = CIEANBarcodeGenerator.codingMap[n][2] // guard (G)
            }
            bars.append(contentsOf: toBitArray(value))
        }
        bars.append(contentsOf: [0, 1, 0, 1, 0]) // middle
        for nRaw in rightPart {
            let n = Int(nRaw)
            let value = CIEANBarcodeGenerator.codingMap[n][1] // right (R)
            bars.append(contentsOf: toBitArray(value))
        }
        bars.append(contentsOf: [1, 0, 1]) // end
        return bars
    }

    private func toBitArray(_ value: UInt8) -> [UInt8] {
        var bits: [UInt8] = []
        for i in 0..<7 {
            bits.append(value & (1 << (6 - i)) == 0 ? 0 : 1)
        }
        return bits
    }

    private func drawBarcode(bars:[UInt8]) -> CIImage? {
        guard let kernel = CIColorKernel(source: CIEANBarcodeGenerator.kernelSrc) else {
            return nil
        }
        var args: [Any] = [bars.count]
        var vector: [CGFloat] = []
        var value: Int32 = 0
        for i in 0..<bars.count {
            if i > 0 && i % 24 == 0 {
                vector.append(CGFloat(value))
                value = 0
            }
            if bars[i] == 1 {
                value = value | (Int32(1) << (i % 24))
            }
        }
        vector.append(CGFloat(value))
        args.append(CIVector(values: vector, count: vector.count))
        let width: CGFloat = CGFloat(bars.count)
        let height: CGFloat = 32.0
        return kernel.apply(extent: CGRect(x: 0, y: 0, width: width, height: height),
                            arguments: args)
    }

    // MARK: - Validation

    private func validateEAN13Barcode(_ barcode: [UInt8]) -> Bool {
        guard barcode.count == 13 else { return false }
        return checkSum(barcode) == 0
    }

    private func validateUPCABarcode(_ barcode: [UInt8]) -> Bool {
        guard barcode.count == 12 else { return false }
        return checkSum(barcode) == 0
    }

    private func validateEAN8Barcode(_ barcode: [UInt8]) -> Bool {
        guard barcode.count == 8 else { return false }
        let expected = computeEAN8CheckDigit(Array(barcode[0...6]))
        return expected == barcode[7]
    }

    private func validateUPCEBarcode(_ barcode: [UInt8]) -> Bool {
        guard barcode.count == 8 else { return false }
        let numberSystem = barcode[0]
        if numberSystem > 1 { return false }
        let dataPart = Array(barcode[0...6])
        let expanded = expandUPCE(dataPart) // 11 digits (UPC-A without check)
        if expanded.count != 11 { return false }
        let expected = computeUPCACheckDigit(expanded)
        return expected == barcode[7]
    }

    // Existing checksum (kept for EAN-13 / UPC-A compatibility)
    private func checkSum(_ barcode: [UInt8]) -> UInt8 {
        var checkSum: UInt8 = 0
        for i in 0..<barcode.count {
            checkSum = (checkSum + (i % 2 == 0 ? barcode[i] : barcode[i] * 3)) % 10
        }
        return checkSum
    }

    // MARK: - Check digit computations

    private func computeEAN8CheckDigit(_ digits: [UInt8]) -> UInt8 {
        // digits length 7
        var sumOdd = 0
        var sumEven = 0
        for i in 0..<digits.count {
            if i % 2 == 0 {
                sumOdd += Int(digits[i])
            } else {
                sumEven += Int(digits[i])
            }
        }
        let total = sumOdd * 3 + sumEven
        let mod = total % 10
        return mod == 0 ? 0 : UInt8(10 - mod)
    }

    private func computeUPCACheckDigit(_ digits: [UInt8]) -> UInt8 {
        // digits length 11 (number system + 10 data)
        var sumOdd = 0
        var sumEven = 0
        for i in 0..<digits.count {
            if i % 2 == 0 {
                sumOdd += Int(digits[i])
            } else {
                sumEven += Int(digits[i])
            }
        }
        let total = sumOdd * 3 + sumEven
        let mod = total % 10
        return mod == 0 ? 0 : UInt8(10 - mod)
    }

    // MARK: - UPC-E Expansion

    private func expandUPCE(_ digits: [UInt8]) -> [UInt8] {
        // digits: number system + 6 data digits (length 7)
        guard digits.count == 7 else { return [] }
        let ns = digits[0]
        let m1 = digits[1], m2 = digits[2], m3 = digits[3], m4 = digits[4], m5 = digits[5], m6 = digits[6]
        var manufacturer: [UInt8] = []
        var product: [UInt8] = []
        switch m6 {
        case 0,1,2:
            manufacturer = [m1, m2, m6, 0, 0]
            product = [0, 0, m3, m4, m5]
        case 3:
            manufacturer = [m1, m2, m3, 0, 0]
            product = [0, 0, 0, m4, m5]
        case 4:
            manufacturer = [m1, m2, m3, m4, 0]
            product = [0, 0, 0, 0, m5]
        default: // 5-9
            manufacturer = [m1, m2, m3, m4, m5]
            product = [0, 0, 0, 0, m6]
        }
        return [ns] + manufacturer + product
    }
}

import Foundation

package struct ISOTypeBufferUtil {
    package let data: Data

    package init(data: Data) {
        self.data = data
    }

    package init?(bytes: UnsafePointer<UInt8>, count: UInt32) {
        self.init(data: Data(bytes: bytes, count: Int(count)))
    }

    package init?(data: Data?) {
        guard let data = data else {
            return nil
        }
        self.init(data: data)
    }

    package func toByteStream() -> Data {
        let buffer = ByteArray(data: data)
        var result = Data()
        while 0 < buffer.bytesAvailable {
            do {
                let length: Int = try Int(buffer.readUInt32())
                result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                result.append(try buffer.readBytes(length))
            } catch {
                logger.error("\(buffer)")
            }
        }
        return result
    }

    static package func toNALFileFormat(_ data: inout Data) {
        var nalRanges: [Range<Int>] = []

        func startCode(at index: Int) -> Int {
            guard index + 2 < data.count else {
                return 0
            }

            if data[index] == 0 &&
               data[index + 1] == 0 {

                if data[index + 2] == 1 {
                    return 3
                }

                if index + 3 < data.count &&
                   data[index + 2] == 0 &&
                   data[index + 3] == 1 {
                    return 4
                }
            }

            return 0
        }

        var index = 0
        var nalStart: Int?

        while index < data.count {
            let codeLength = startCode(at: index)

            if codeLength > 0 {
                if let nalStart {
                    nalRanges.append(nalStart..<index)
                }

                nalStart = index + codeLength
                index += codeLength
            } else {
                index += 1
            }
        }

        if let nalStart, nalStart < data.count {
            nalRanges.append(nalStart..<data.count)
        }

        var output = Data()

        for range in nalRanges {
            let length = UInt32(range.count).bigEndian

            withUnsafeBytes(of: length) {
                output.append(contentsOf: $0)
            }

            output.append(data[range])
        }

        data = output
    }
}

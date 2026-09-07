import Foundation

/// The body of a MIME message part, also returned by `messages.attachments.get`.
public struct GmailMessagePartBody: Decodable, Equatable, Sendable {
  /// An opaque identifier for content retrieved with a separate attachment request.
  /// A missing identifier indicates that content is supplied in `data`, when present.
  public let attachmentId: String?

  /// The number of body bytes before base64url encoding, when supplied.
  /// A missing size is unknown, not necessarily zero.
  public let size: Int?

  /// The base64url-encoded content, preserved exactly as Gmail returned it.
  /// This may be absent or empty for container parts or separately fetched attachments.
  /// Decode to bytes before interpreting text using the part's declared character set.
  public let data: String?

  /// Decodes `data` from padded or unpadded base64url into bytes, preserving the source string.
  /// Returns nil for missing data and empty bytes for an empty string.
  /// Does not fetch `attachmentId` content, verify `size`, or interpret a text character set.
  /// Throws `ContentDecodingError.invalidBase64URL` for invalid characters, length, or padding.
  public func decodedData() throws -> Data? {
    guard let encodedContent = data else { return nil }
    let paddingStart = encodedContent.firstIndex(of: "=") ?? encodedContent.endIndex
    let unpaddedContent = encodedContent[..<paddingStart]
    let suppliedPadding = encodedContent[paddingStart...]
    guard unpaddedContent.rangeOfCharacter(from: Constant.base64URLAlphabet.inverted) == nil,
      suppliedPadding.allSatisfy({ $0 == "=" })
    else {
      throw ContentDecodingError.invalidBase64URL
    }

    let trailingCharacterCount = unpaddedContent.utf8.count % Constant.base64BlockLength
    let requiredPaddingCount =
      (Constant.base64BlockLength - trailingCharacterCount) % Constant.base64BlockLength
    // One trailing character cannot represent a complete byte.
    guard trailingCharacterCount != Constant.invalidTrailingCharacterCount,
      suppliedPadding.isEmpty || suppliedPadding.count == requiredPaddingCount
    else {
      throw ContentDecodingError.invalidBase64URL
    }

    let base64Content = unpaddedContent
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: requiredPaddingCount)
    guard let decodedContent = Data(base64Encoded: base64Content) else {
      throw ContentDecodingError.invalidBase64URL
    }
    return decodedContent
  }
}

private extension GmailMessagePartBody {
  enum Constant {
    static let base64URLAlphabet: CharacterSet = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    static let base64BlockLength: Int = 4
    static let invalidTrailingCharacterCount: Int = 1
  }
}

extension GmailMessagePartBody {
  public enum ContentDecodingError: LocalizedError, Equatable {
    case invalidBase64URL

    public var errorDescription: String? {
      "The Gmail message body could not be decoded."
    }

    public var failureReason: String? {
      "The body data contains invalid base64url characters, length, or padding."
    }

    public var recoverySuggestion: String? {
      "Fetch the message or attachment again and verify the encoded body data if the problem persists."
    }
  }
}

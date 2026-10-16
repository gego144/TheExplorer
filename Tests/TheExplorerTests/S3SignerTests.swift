import Foundation
import Testing
@testable import TheExplorer

/// Checked against the examples in AWS's Signature Version 4 documentation and test suite.
struct S3SignerTests {
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: text)!
    }

    @Test func getVanillaFromTheSigV4TestSuite() {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let credentials = S3Credentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        S3Signer.sign(&request, credentials: credentials, region: "us-east-1", service: "service",
                      payloadHash: S3Signer.emptyPayloadHash, date: date("20150830T123600Z"), signContentHash: false)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    private let docsCredentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    @Test func s3GetObjectExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        S3Signer.sign(&request, credentials: docsCredentials, region: "us-east-1",
                      payloadHash: S3Signer.emptyPayloadHash, date: date("20130524T000000Z"))
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func s3PresignedURLExample() {
        let url = S3Signer.presign(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, credentials: docsCredentials,
                                   region: "us-east-1", expires: 86400, date: date("20130524T000000Z"))
        #expect(url?.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") == true)
    }

    @Test func encodesKeysLikeAWS() {
        #expect(S3Signer.encode("photos/2026 trip/a+b&c.jpg", keepSlashes: true) == "photos/2026%20trip/a%2Bb%26c.jpg")
        #expect(S3Signer.encode("a/b") == "a%2Fb")
    }
}

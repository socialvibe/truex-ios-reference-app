// Temporary workaround: fetches VAST configs for TrueX/IDVx before stream
// initialization. This is NOT part of a standard IMA DAI integration — it exists
// because we don't have access to the GAM ad source configuration.

import Foundation
import ObjectiveC
import UIKit

private var vastConfigsKey: UInt8 = 0

extension SSAIGAMRefController {

    var vastConfigs: [String: Data]? {
        get { objc_getAssociatedObject(self, &vastConfigsKey) as? [String: Data] }
        set { objc_setAssociatedObject(self, &vastConfigsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func loadVASTConfigs(onSuccess: @escaping () -> Void) {
        fetchVASTConfigs { [weak self] success in
            guard success else {
                self?.showVASTConfigError()
                return
            }
            onSuccess()
        }
    }

    private func showVASTConfigError() {
        let alert = UIAlertController(
            title: "Error",
            message: "Failed to load ad configuration. Please check your internet connection and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    private func fetchVASTConfigs(completion: @escaping (Bool) -> Void) {
        let urls: [(String, URL)] = [
            ("truex", URL(string: "https://get.truex.com/22c36d3926383ba62994809a60b4649e3ced1070/vast/generic?ip=108.213.126.254")!),
            ("idvx", URL(string: "https://get.truex.com/132f66121635ac312e42f1eb018081d50d10fe2a/vast/idvx/generic?ip=108.213.126.254")!),
        ]

        let group = DispatchGroup()
        var results: [String: Data] = [:]
        let lock = NSLock()

        for (key, url) in urls {
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, error in
                if let data = data {
                    lock.lock()
                    results[key] = data
                    lock.unlock()
                    print("[SSAIGAMRef] Fetched VAST config: \(key) (\(data.count) bytes)")
                } else if let error = error {
                    print("[SSAIGAMRef] Failed to fetch VAST config (\(key)): \(error.localizedDescription)")
                }
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard results.count == urls.count else {
                completion(false)
                return
            }
            self?.vastConfigs = results
            completion(true)
        }
    }

    func extractAdParameters(from vastData: Data) -> [String: Any]? {
        final class AdParametersParser: NSObject, XMLParserDelegate {
            private var currentElement: String?
            private var buffer = ""
            private(set) var adParametersText: String?

            func parser(_ parser: XMLParser, didStartElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                currentElement = elementName
                if elementName == "AdParameters" {
                    buffer = ""
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                guard currentElement == "AdParameters" else { return }
                buffer += string
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?) {
                if elementName == "AdParameters" {
                    adParametersText = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentElement = nil
            }
        }

        let parser = XMLParser(data: vastData)
        let delegate = AdParametersParser()
        parser.delegate = delegate
        guard parser.parse(), let text = delegate.adParametersText, !text.isEmpty else {
            return nil
        }

        guard let jsonData = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
    }
}

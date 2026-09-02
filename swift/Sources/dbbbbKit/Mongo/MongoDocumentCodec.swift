import Foundation
import dbbbbCore

/// Public bridge between the app's document-editing UI and dbbbb's canonical
/// Extended JSON codec: the editing sheet shows a document as EJSON text and
/// parses the edited text back into display pairs.
public enum MongoDocumentCodec {
    /// Serializes displayed document fields as canonical Extended JSON.
    public static func ejsonText(
        from pairs: [(key: String, value: DisplayValue)]
    ) throws -> String {
        let document = try pairs.map { pair -> (key: String, value: BSONValue) in
            (pair.key, try MongoChangePlanner.bsonValue(from: pair.value, label: "The document"))
        }
        return EJSONSerializer.serialize(document: document)
    }

    /// Parses edited canonical Extended JSON text back into display pairs.
    public static func displayPairs(
        fromEJSON text: String
    ) throws -> [(key: String, value: DisplayValue)] {
        let bson: BSONValue
        do {
            bson = try EJSON.parseDocument(text, label: "The edited document")
        } catch let error as EJSONError {
            throw MongoAdapterError.invalidExtendedJSON(error.userMessage)
        }
        guard case .document(let pairs) = bson,
              case .object(let display) = MongoDisplayValue.convert(.document(pairs))
        else {
            throw MongoAdapterError.invalidExtendedJSON(
                EJSONError.expectedDocument("The edited document").userMessage)
        }
        return display
    }
}

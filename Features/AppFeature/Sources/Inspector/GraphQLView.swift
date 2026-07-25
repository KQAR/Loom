import LoomSharedModels
import SwiftUI

/// GraphQL view: operation label, the query (monospaced), and pretty variables.
struct GraphQLView: View {
    let operation: GraphQLOperation?

    var body: some View {
        if let operation {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                HStack(spacing: LoomTheme.Space.xs) {
                    CapsuleBadge(text: operation.kind.rawValue)
                    if let name = operation.operationName, !name.isEmpty {
                        Text(name).font(.callout.weight(.semibold))
                    }
                }
                Text("Query").font(.caption).foregroundStyle(.secondary)
                Text(operation.query)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let variables = operation.variablesJSON {
                    Text("Variables").font(.caption).foregroundStyle(.secondary)
                    if let json = JSONValue.parse(Data(variables.utf8)), json.isContainer {
                        JSONView(value: json)
                    } else {
                        Text(variables).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text("Not a GraphQL request").foregroundStyle(.secondary)
        }
    }
}

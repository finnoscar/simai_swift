// Mechanical access-control adaptation of the explicitly exported Airmai files.
// Uses SwiftSyntax shipped with Xcode. Runtime targets have no such dependency.
import Foundation
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax

final class PublicAPIRewriter: SyntaxRewriter {
    private func isPrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            ["private", "fileprivate"].contains(modifier.name.text) && modifier.detail == nil
        }
    }

    private func exported(_ modifiers: DeclModifierListSyntax) -> DeclModifierListSyntax {
        guard !modifiers.contains(where: { ["public", "open"].contains($0.name.text) }) else {
            return modifiers
        }
        var result = modifiers
        let leading = result.first?.leadingTrivia ?? []
        if !result.isEmpty { result[result.startIndex].leadingTrivia = [] }
        result.insert(DeclModifierSyntax(leadingTrivia: leading, name: .keyword(.public), trailingTrivia: .space), at: result.startIndex)
        return result
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = super.visit(node).cast(StructDeclSyntax.self)
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = super.visit(node).cast(ClassDeclSyntax.self)
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }

    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = super.visit(node).cast(EnumDeclSyntax.self)
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        isPrivate(node.modifiers) ? DeclSyntax(node) : super.visit(node)
    }

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = node
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = node
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        guard !isPrivate(node.modifiers) else { return DeclSyntax(node) }
        var result = node
        let trivia = result.leadingTrivia
        result.leadingTrivia = []
        result.modifiers = exported(result.modifiers)
        result.leadingTrivia = trivia
        return DeclSyntax(result)
    }
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: Publicize <source.swift>")
}
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let tree = Parser.parse(source: source)
print(PublicAPIRewriter().rewrite(tree).formatted().description, terminator: "")

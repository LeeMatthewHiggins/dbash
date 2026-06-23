/// Abstract Syntax Tree (AST) types for bash.
///
/// Faithful port of `ast/types.ts` from upstream just-bash. Each node carries a
/// [AstNode.type] discriminant string identical to the upstream node `type`
/// field, so serialized trees can be compared against the original.
///
/// The deeply nested node tree means a couple of stylistic lints fight the
/// mechanical shape of this port; they are disabled file-wide.
// ignore_for_file: lines_longer_than_80_chars
// AST node constructors mirror the upstream positional field order.
// ignore_for_file: avoid_positional_boolean_parameters
library;

/// Base class for all AST nodes.
abstract class AstNode {
  /// The discriminant string (matches upstream node `type`).
  String get type;

  /// Source line number (1-based) for `$LINENO`. May be null for synthesized
  /// nodes.
  int? line;
}

// =============================================================================
// SCRIPT & STATEMENTS
// =============================================================================

/// Root node: a complete script.
class ScriptNode extends AstNode {
  /// Creates a script of [statements].
  ScriptNode(this.statements);

  /// The top-level statements.
  final List<StatementNode> statements;

  @override
  String get type => 'Script';
}

/// A deferred syntax error attached to a statement (bash's incremental parsing).
class DeferredError {
  /// Creates a deferred error.
  const DeferredError(this.message, this.token);

  /// The error message.
  final String message;

  /// The offending token text.
  final String token;
}

/// A statement: a list of pipelines connected by `&&`/`||`/`;`.
class StatementNode extends AstNode {
  /// Creates a statement.
  StatementNode(
    this.pipelines, {
    this.operators = const [],
    this.background = false,
    this.deferredError,
    this.sourceText,
  });

  /// The pipelines in this statement.
  final List<PipelineNode> pipelines;

  /// Operators between pipelines (`&&`, `||`, `;`).
  final List<String> operators;

  /// Whether the statement runs in the background.
  bool background;

  /// A deferred syntax error, if any.
  DeferredError? deferredError;

  /// Original source text for `set -v`.
  String? sourceText;

  @override
  String get type => 'Statement';
}

// =============================================================================
// PIPELINES & COMMANDS
// =============================================================================

/// A pipeline: `cmd1 | cmd2 | cmd3`.
class PipelineNode extends AstNode {
  /// Creates a pipeline.
  PipelineNode(
    this.commands, {
    this.negated = false,
    this.timed = false,
    this.timePosix = false,
    this.pipeStderr,
  });

  /// The commands joined by pipes.
  final List<CommandNode> commands;

  /// Whether the exit status is negated with `!`.
  bool negated;

  /// Whether the pipeline is timed with `time`.
  bool timed;

  /// Whether `time -p` POSIX format is used.
  bool timePosix;

  /// For each pipe, whether it is `|&` (also pipes stderr). Length is
  /// `commands.length - 1`.
  List<bool>? pipeStderr;

  @override
  String get type => 'Pipeline';
}

/// Union of all command types.
sealed class CommandNode extends AstNode {}

/// A simple command: `name args...` with optional redirections.
class SimpleCommandNode extends CommandNode {
  /// Creates a simple command.
  SimpleCommandNode({
    required this.name,
    this.args = const [],
    this.assignments = const [],
    this.redirections = const [],
  });

  /// Variable assignments before the command.
  List<AssignmentNode> assignments;

  /// The command name (null for assignment-only commands).
  WordNode? name;

  /// The command arguments.
  List<WordNode> args;

  /// The I/O redirections.
  List<RedirectionNode> redirections;

  @override
  String get type => 'SimpleCommand';
}

/// Compound commands: control structures.
sealed class CompoundCommandNode extends CommandNode {}

// =============================================================================
// CONTROL FLOW
// =============================================================================

/// A single `if`/`elif` clause.
class IfClause {
  /// Creates an if-clause.
  const IfClause(this.condition, this.body);

  /// The condition statements.
  final List<StatementNode> condition;

  /// The body statements.
  final List<StatementNode> body;
}

/// An `if` statement.
class IfNode extends CompoundCommandNode {
  /// Creates an if node.
  IfNode(this.clauses, {this.elseBody, this.redirections = const []});

  /// The if/elif clauses.
  final List<IfClause> clauses;

  /// The else body, or null.
  List<StatementNode>? elseBody;

  /// Redirections applied to the whole `if`.
  List<RedirectionNode> redirections;

  @override
  String get type => 'If';
}

/// A `for VAR in WORDS; do ...; done` loop.
class ForNode extends CompoundCommandNode {
  /// Creates a for node.
  ForNode(this.variable, this.words, this.body, {this.redirections = const []});

  /// The loop variable.
  final String variable;

  /// Words to iterate over (null = `"$@"`).
  List<WordNode>? words;

  /// The loop body.
  List<StatementNode> body;

  /// Redirections applied to the loop.
  List<RedirectionNode> redirections;

  @override
  String get type => 'For';
}

/// A C-style `for ((init; cond; step))` loop.
class CStyleForNode extends CompoundCommandNode {
  /// Creates a C-style for node.
  CStyleForNode({
    required this.init,
    required this.condition,
    required this.update,
    required this.body,
    this.redirections = const [],
  });

  /// The init expression, or null.
  ArithmeticExpressionNode? init;

  /// The loop condition, or null.
  ArithmeticExpressionNode? condition;

  /// The update expression, or null.
  ArithmeticExpressionNode? update;

  /// The loop body.
  List<StatementNode> body;

  /// Redirections applied to the loop.
  List<RedirectionNode> redirections;

  @override
  String get type => 'CStyleFor';
}

/// A `while` loop.
class WhileNode extends CompoundCommandNode {
  /// Creates a while node.
  WhileNode(this.condition, this.body, {this.redirections = const []});

  /// The condition statements.
  List<StatementNode> condition;

  /// The loop body.
  List<StatementNode> body;

  /// Redirections applied to the loop.
  List<RedirectionNode> redirections;

  @override
  String get type => 'While';
}

/// An `until` loop.
class UntilNode extends CompoundCommandNode {
  /// Creates an until node.
  UntilNode(this.condition, this.body, {this.redirections = const []});

  /// The condition statements.
  List<StatementNode> condition;

  /// The loop body.
  List<StatementNode> body;

  /// Redirections applied to the loop.
  List<RedirectionNode> redirections;

  @override
  String get type => 'Until';
}

/// A `case` statement.
class CaseNode extends CompoundCommandNode {
  /// Creates a case node.
  CaseNode(this.word, this.items, {this.redirections = const []});

  /// The word being matched.
  WordNode word;

  /// The case items.
  List<CaseItemNode> items;

  /// Redirections applied to the whole `case`.
  List<RedirectionNode> redirections;

  @override
  String get type => 'Case';
}

/// A single `case` item (patterns + body + terminator).
class CaseItemNode extends AstNode {
  /// Creates a case item.
  CaseItemNode(this.patterns, this.body, {this.terminator = ';;'});

  /// The patterns for this item.
  List<WordNode> patterns;

  /// The item body.
  List<StatementNode> body;

  /// The terminator (`;;`, `;&`, `;;&`).
  String terminator;

  @override
  String get type => 'CaseItem';
}

/// A subshell: `( ... )`.
class SubshellNode extends CompoundCommandNode {
  /// Creates a subshell node.
  SubshellNode(this.body, {this.redirections = const []});

  /// The subshell body.
  List<StatementNode> body;

  /// Redirections applied to the subshell.
  List<RedirectionNode> redirections;

  @override
  String get type => 'Subshell';
}

/// A command group: `{ ...; }`.
class GroupNode extends CompoundCommandNode {
  /// Creates a group node.
  GroupNode(this.body, {this.redirections = const []});

  /// The group body.
  List<StatementNode> body;

  /// Redirections applied to the group.
  List<RedirectionNode> redirections;

  @override
  String get type => 'Group';
}

/// An arithmetic command: `(( expr ))`.
class ArithmeticCommandNode extends CompoundCommandNode {
  /// Creates an arithmetic command node.
  ArithmeticCommandNode(this.expression, {this.redirections = const []});

  /// The arithmetic expression.
  ArithmeticExpressionNode expression;

  /// Redirections applied to the command.
  List<RedirectionNode> redirections;

  @override
  String get type => 'ArithmeticCommand';
}

/// A conditional command: `[[ expr ]]`.
class ConditionalCommandNode extends CompoundCommandNode {
  /// Creates a conditional command node.
  ConditionalCommandNode(
    this.expression, {
    this.redirections = const [],
    int? line,
  }) {
    this.line = line;
  }

  /// The conditional expression.
  ConditionalExpressionNode expression;

  /// Redirections applied to the command.
  List<RedirectionNode> redirections;

  @override
  String get type => 'ConditionalCommand';
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/// A function definition.
class FunctionDefNode extends CommandNode {
  /// Creates a function definition node.
  FunctionDefNode(
    this.name,
    this.body, {
    this.redirections = const [],
    this.sourceFile,
  });

  /// The function name.
  final String name;

  /// The function body (a compound command).
  CompoundCommandNode body;

  /// Redirections applied to the function.
  List<RedirectionNode> redirections;

  /// Source file where the function was defined (for `BASH_SOURCE`).
  String? sourceFile;

  @override
  String get type => 'FunctionDef';
}

// =============================================================================
// ASSIGNMENTS
// =============================================================================

/// A variable assignment: `VAR=value` or `VAR+=value`.
class AssignmentNode extends AstNode {
  /// Creates an assignment node.
  AssignmentNode(this.name, this.value, {this.append = false, this.array});

  /// The variable name (may include a subscript).
  final String name;

  /// The assigned value word, or null.
  WordNode? value;

  /// Whether this is an append (`+=`) assignment.
  bool append;

  /// The array elements for `VAR=(a b c)`, or null.
  List<WordNode>? array;

  @override
  String get type => 'Assignment';
}

// =============================================================================
// REDIRECTIONS
// =============================================================================

/// An I/O redirection.
class RedirectionNode extends AstNode {
  /// Creates a redirection node.
  RedirectionNode(this.operator, this.target, {this.fd, this.fdVariable});

  /// The file descriptor, or null for the operator default.
  int? fd;

  /// Variable name for `{varname}>file` automatic FD allocation.
  String? fdVariable;

  /// The redirection operator.
  String operator;

  /// The target — a [WordNode] or [HereDocNode].
  AstNode target;

  @override
  String get type => 'Redirection';
}

/// A here-document.
class HereDocNode extends AstNode {
  /// Creates a here-doc node.
  HereDocNode(
    this.delimiter,
    this.content, {
    this.stripTabs = false,
    this.quoted = false,
  });

  /// The delimiter word.
  String delimiter;

  /// The here-doc content.
  WordNode content;

  /// Whether leading tabs are stripped (`<<-`).
  bool stripTabs;

  /// Whether the delimiter was quoted (no expansion).
  bool quoted;

  @override
  String get type => 'HereDoc';
}

// =============================================================================
// WORDS
// =============================================================================

/// A word: a sequence of [WordPart]s forming a single shell word.
class WordNode extends AstNode {
  /// Creates a word node.
  WordNode(this.parts);

  /// The parts making up this word.
  List<WordPart> parts;

  @override
  String get type => 'Word';
}

/// A part of a [WordNode].
sealed class WordPart extends AstNode {}

/// Literal text (no special meaning).
class LiteralPart extends WordPart {
  /// Creates a literal part.
  LiteralPart(this.value);

  /// The literal text.
  final String value;

  @override
  String get type => 'Literal';
}

/// A single-quoted string.
class SingleQuotedPart extends WordPart {
  /// Creates a single-quoted part.
  SingleQuotedPart(this.value);

  /// The quoted text.
  final String value;

  @override
  String get type => 'SingleQuoted';
}

/// A double-quoted string, which may contain expansions.
class DoubleQuotedPart extends WordPart {
  /// Creates a double-quoted part.
  DoubleQuotedPart(this.parts);

  /// The parts inside the double quotes.
  final List<WordPart> parts;

  @override
  String get type => 'DoubleQuoted';
}

/// An escaped character: `\x`.
class EscapedPart extends WordPart {
  /// Creates an escaped part.
  EscapedPart(this.value);

  /// The escaped character.
  final String value;

  @override
  String get type => 'Escaped';
}

// =============================================================================
// PARAMETER EXPANSION
// =============================================================================

/// A parameter/variable expansion: `$VAR` or `${VAR...}`.
class ParameterExpansionPart extends WordPart {
  /// Creates a parameter-expansion part.
  ParameterExpansionPart(this.parameter, [this.operation]);

  /// The parameter name.
  final String parameter;

  /// The expansion operation, or null.
  ParameterOperation? operation;

  @override
  String get type => 'ParameterExpansion';
}

/// Marker for operations usable as the inner op of `${!ref-default}`.
abstract interface class InnerParameterOperation {}

/// An operation applied within a parameter expansion.
sealed class ParameterOperation {
  /// The discriminant string.
  String get type;
}

/// `${#VAR:...}` — invalid: length cannot have a substring.
class LengthSliceErrorOp extends ParameterOperation
    implements InnerParameterOperation {
  @override
  String get type => 'LengthSliceError';
}

/// A bad substitution, parsed but errors at runtime.
class BadSubstitutionOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a bad-substitution op carrying the offending [text].
  BadSubstitutionOp(this.text);

  /// The raw text that caused the error.
  final String text;

  @override
  String get type => 'BadSubstitution';
}

/// `${VAR:-default}` / `${VAR-default}`.
class DefaultValueOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a default-value op.
  DefaultValueOp(this.word, this.checkEmpty);

  /// The default word.
  final WordNode word;

  /// Whether `:` is present (also checks for empty).
  final bool checkEmpty;

  @override
  String get type => 'DefaultValue';
}

/// `${VAR:=default}` / `${VAR=default}`.
class AssignDefaultOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates an assign-default op.
  AssignDefaultOp(this.word, this.checkEmpty);

  /// The default word to assign.
  final WordNode word;

  /// Whether `:` is present.
  final bool checkEmpty;

  @override
  String get type => 'AssignDefault';
}

/// `${VAR:?error}` / `${VAR?error}`.
class ErrorIfUnsetOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates an error-if-unset op.
  ErrorIfUnsetOp(this.word, this.checkEmpty);

  /// The error word, or null.
  final WordNode? word;

  /// Whether `:` is present.
  final bool checkEmpty;

  @override
  String get type => 'ErrorIfUnset';
}

/// `${VAR:+alt}` / `${VAR+alt}`.
class UseAlternativeOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a use-alternative op.
  UseAlternativeOp(this.word, this.checkEmpty);

  /// The alternative word.
  final WordNode word;

  /// Whether `:` is present.
  final bool checkEmpty;

  @override
  String get type => 'UseAlternative';
}

/// `${#VAR}` — length.
class LengthOp extends ParameterOperation implements InnerParameterOperation {
  @override
  String get type => 'Length';
}

/// `${VAR:offset}` / `${VAR:offset:length}`.
class SubstringOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a substring op.
  SubstringOp(this.offset, this.length);

  /// The offset expression.
  final ArithmeticExpressionNode offset;

  /// The length expression, or null.
  final ArithmeticExpressionNode? length;

  @override
  String get type => 'Substring';
}

/// `${VAR#pat}`, `${VAR##pat}`, `${VAR%pat}`, `${VAR%%pat}`.
class PatternRemovalOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a pattern-removal op.
  PatternRemovalOp(this.pattern, this.side, this.greedy);

  /// The pattern word.
  final WordNode pattern;

  /// `prefix` (`#`/`##`) or `suffix` (`%`/`%%`).
  final String side;

  /// Whether greedy (`##`/`%%`).
  final bool greedy;

  @override
  String get type => 'PatternRemoval';
}

/// `${VAR/pat/rep}` / `${VAR//pat/rep}`.
class PatternReplacementOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a pattern-replacement op.
  PatternReplacementOp(this.pattern, this.replacement, this.all, this.anchor);

  /// The pattern word.
  final WordNode pattern;

  /// The replacement word, or null.
  final WordNode? replacement;

  /// Whether to replace all occurrences.
  final bool all;

  /// `start` (`#`), `end` (`%`), or null.
  final String? anchor;

  @override
  String get type => 'PatternReplacement';
}

/// `${VAR^}`, `${VAR^^}`, `${VAR,}`, `${VAR,,}`.
class CaseModificationOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a case-modification op.
  CaseModificationOp(this.direction, this.all, this.pattern);

  /// `upper` (`^`) or `lower` (`,`).
  final String direction;

  /// Whether applied to all characters (`^^`/`,,`).
  final bool all;

  /// An optional pattern restricting which characters change.
  final WordNode? pattern;

  @override
  String get type => 'CaseModification';
}

/// `${var@Q}`, `${var@P}`, etc.
class TransformOp extends ParameterOperation
    implements InnerParameterOperation {
  /// Creates a transform op.
  TransformOp(this.operator);

  /// The transform operator character.
  final String operator;

  @override
  String get type => 'Transform';
}

/// `${!VAR}` — indirect expansion, optionally with an inner op.
class IndirectionOp extends ParameterOperation {
  /// Creates an indirection op.
  IndirectionOp([this.innerOp]);

  /// An additional operation applied after indirection.
  final InnerParameterOperation? innerOp;

  @override
  String get type => 'Indirection';
}

/// `${!arr[@]}` / `${!arr[*]}` — array keys/indices.
class ArrayKeysOp extends ParameterOperation {
  /// Creates an array-keys op.
  ArrayKeysOp(this.array, this.star);

  /// The array name.
  final String array;

  /// Whether `[*]` was used instead of `[@]`.
  final bool star;

  @override
  String get type => 'ArrayKeys';
}

/// `${!prefix*}` / `${!prefix@}` — variable names with a prefix.
class VarNamePrefixOp extends ParameterOperation {
  /// Creates a var-name-prefix op.
  VarNamePrefixOp(this.prefix, this.star);

  /// The prefix to match.
  final String prefix;

  /// Whether `*` was used instead of `@`.
  final bool star;

  @override
  String get type => 'VarNamePrefix';
}

// =============================================================================
// COMMAND SUBSTITUTION
// =============================================================================

/// Command substitution: `$(cmd)` or `` `cmd` ``.
class CommandSubstitutionPart extends WordPart {
  /// Creates a command-substitution part.
  CommandSubstitutionPart(this.body, {this.legacy = false});

  /// The substituted script.
  final ScriptNode body;

  /// Whether legacy backtick syntax was used.
  final bool legacy;

  @override
  String get type => 'CommandSubstitution';
}

// =============================================================================
// ARITHMETIC
// =============================================================================

/// Arithmetic expansion: `$((expr))`.
class ArithmeticExpansionPart extends WordPart {
  /// Creates an arithmetic-expansion part.
  ArithmeticExpansionPart(this.expression);

  /// The arithmetic expression.
  final ArithmeticExpressionNode expression;

  @override
  String get type => 'ArithmeticExpansion';
}

/// An arithmetic expression wrapper (for `$((...))` and `((...))`).
class ArithmeticExpressionNode extends AstNode {
  /// Creates an arithmetic expression node.
  ArithmeticExpressionNode(this.expression, {this.originalText});

  /// The root arithmetic expression.
  ArithExpr expression;

  /// Original text before parsing, for re-parsing after expansion.
  String? originalText;

  @override
  String get type => 'ArithmeticExpression';
}

/// An arithmetic expression node.
sealed class ArithExpr extends AstNode {}

/// `${...}` braced expansion inside arithmetic.
class ArithBracedExpansionNode extends ArithExpr {
  /// Creates a braced-expansion node.
  ArithBracedExpansionNode(this.content);

  /// The content inside `${...}`.
  final String content;

  @override
  String get type => 'ArithBracedExpansion';
}

/// Dynamic base constant `${base}#value`.
class ArithDynamicBaseNode extends ArithExpr {
  /// Creates a dynamic-base node.
  ArithDynamicBaseNode(this.baseExpr, this.value);

  /// The base variable content.
  final String baseExpr;

  /// The value after `#`.
  final String value;

  @override
  String get type => 'ArithDynamicBase';
}

/// Dynamic number prefix `${zero}11`.
class ArithDynamicNumberNode extends ArithExpr {
  /// Creates a dynamic-number node.
  ArithDynamicNumberNode(this.prefix, this.suffix);

  /// The variable content prefix.
  final String prefix;

  /// The numeric suffix.
  final String suffix;

  @override
  String get type => 'ArithDynamicNumber';
}

/// Concatenation of parts forming a single numeric value.
class ArithConcatNode extends ArithExpr {
  /// Creates a concat node.
  ArithConcatNode(this.parts);

  /// The parts to concatenate.
  final List<ArithExpr> parts;

  @override
  String get type => 'ArithConcat';
}

/// An array element reference `arr[index]`.
class ArithArrayElementNode extends ArithExpr {
  /// Creates an array-element node.
  ArithArrayElementNode(this.array, {this.index, this.stringKey});

  /// The array name.
  final String array;

  /// The index expression (numeric indices).
  final ArithExpr? index;

  /// A literal string key (associative arrays).
  final String? stringKey;

  @override
  String get type => 'ArithArrayElement';
}

/// An invalid double subscript `a[1][1]` (errors at runtime).
class ArithDoubleSubscriptNode extends ArithExpr {
  /// Creates a double-subscript node.
  ArithDoubleSubscriptNode(this.array, this.index);

  /// The array name.
  final String array;

  /// The first index expression.
  final ArithExpr index;

  @override
  String get type => 'ArithDoubleSubscript';
}

/// An invalid number subscript `1[2]` (errors at runtime).
class ArithNumberSubscriptNode extends ArithExpr {
  /// Creates a number-subscript node.
  ArithNumberSubscriptNode(this.number, this.errorToken);

  /// The number that was subscripted.
  final String number;

  /// The error token for the message.
  final String errorToken;

  @override
  String get type => 'ArithNumberSubscript';
}

/// A syntax error in an arithmetic expression (errors at runtime).
class ArithSyntaxErrorNode extends ArithExpr {
  /// Creates a syntax-error node.
  ArithSyntaxErrorNode(this.errorToken, this.message);

  /// The invalid token.
  final String errorToken;

  /// The error message.
  final String message;

  @override
  String get type => 'ArithSyntaxError';
}

/// A single-quoted string in arithmetic.
class ArithSingleQuoteNode extends ArithExpr {
  /// Creates a single-quote node.
  ArithSingleQuoteNode(this.content, this.value);

  /// The content inside the quotes.
  final String content;

  /// The numeric value (command context).
  final num value;

  @override
  String get type => 'ArithSingleQuote';
}

/// A numeric literal.
class ArithNumberNode extends ArithExpr {
  /// Creates a number node.
  ArithNumberNode(this.value);

  /// The numeric value.
  final num value;

  @override
  String get type => 'ArithNumber';
}

/// A variable reference.
class ArithVariableNode extends ArithExpr {
  /// Creates a variable node.
  ArithVariableNode(this.name, {this.hasDollarPrefix});

  /// The variable name.
  final String name;

  /// Whether written with a `$` prefix.
  final bool? hasDollarPrefix;

  @override
  String get type => 'ArithVariable';
}

/// A special variable `$*`, `$@`, `$#`, `$?`, `$-`, `$!`, `$$`.
class ArithSpecialVarNode extends ArithExpr {
  /// Creates a special-variable node.
  ArithSpecialVarNode(this.name);

  /// The special variable character.
  final String name;

  @override
  String get type => 'ArithSpecialVar';
}

/// A binary arithmetic operation.
class ArithBinaryNode extends ArithExpr {
  /// Creates a binary node.
  ArithBinaryNode(this.operator, this.left, this.right);

  /// The operator text.
  final String operator;

  /// The left operand.
  final ArithExpr left;

  /// The right operand.
  final ArithExpr right;

  @override
  String get type => 'ArithBinary';
}

/// A unary arithmetic operation.
class ArithUnaryNode extends ArithExpr {
  /// Creates a unary node.
  ArithUnaryNode(this.operator, this.operand, {required this.prefix});

  /// The operator text.
  final String operator;

  /// The operand.
  final ArithExpr operand;

  /// Whether prefix (vs postfix) for `++`/`--`.
  final bool prefix;

  @override
  String get type => 'ArithUnary';
}

/// A ternary `cond ? a : b`.
class ArithTernaryNode extends ArithExpr {
  /// Creates a ternary node.
  ArithTernaryNode(this.condition, this.consequent, this.alternate);

  /// The condition.
  final ArithExpr condition;

  /// The consequent.
  final ArithExpr consequent;

  /// The alternate.
  final ArithExpr alternate;

  @override
  String get type => 'ArithTernary';
}

/// An assignment `x = expr`.
class ArithAssignmentNode extends ArithExpr {
  /// Creates an assignment node.
  ArithAssignmentNode(
    this.operator,
    this.variable,
    this.value, {
    this.subscript,
    this.stringKey,
  });

  /// The assignment operator.
  final String operator;

  /// The target variable.
  final String variable;

  /// The subscript expression for array assignment.
  final ArithExpr? subscript;

  /// A literal string key for associative arrays.
  final String? stringKey;

  /// The assigned value.
  final ArithExpr value;

  @override
  String get type => 'ArithAssignment';
}

/// A dynamic assignment where the variable name is built by concatenation.
class ArithDynamicAssignmentNode extends ArithExpr {
  /// Creates a dynamic-assignment node.
  ArithDynamicAssignmentNode(
    this.operator,
    this.target,
    this.value, {
    this.subscript,
  });

  /// The assignment operator.
  final String operator;

  /// The target expression evaluating to the variable name.
  final ArithExpr target;

  /// The subscript expression for array assignment.
  final ArithExpr? subscript;

  /// The assigned value.
  final ArithExpr value;

  @override
  String get type => 'ArithDynamicAssignment';
}

/// A dynamic array element where the array name is built by concatenation.
class ArithDynamicElementNode extends ArithExpr {
  /// Creates a dynamic-element node.
  ArithDynamicElementNode(this.nameExpr, this.subscript);

  /// The expression evaluating to the array name.
  final ArithExpr nameExpr;

  /// The subscript expression.
  final ArithExpr subscript;

  @override
  String get type => 'ArithDynamicElement';
}

/// A parenthesized group `( expr )`.
class ArithGroupNode extends ArithExpr {
  /// Creates a group node.
  ArithGroupNode(this.expression);

  /// The grouped expression.
  final ArithExpr expression;

  @override
  String get type => 'ArithGroup';
}

/// A nested arithmetic expansion `$((expr))` within arithmetic.
class ArithNestedNode extends ArithExpr {
  /// Creates a nested node.
  ArithNestedNode(this.expression);

  /// The nested expression.
  final ArithExpr expression;

  @override
  String get type => 'ArithNested';
}

/// A command substitution within arithmetic.
class ArithCommandSubstNode extends ArithExpr {
  /// Creates a command-substitution node.
  ArithCommandSubstNode(this.command);

  /// The raw command text.
  final String command;

  @override
  String get type => 'ArithCommandSubst';
}

// =============================================================================
// PROCESS SUBSTITUTION
// =============================================================================

/// Process substitution: `<(cmd)` or `>(cmd)`.
class ProcessSubstitutionPart extends WordPart {
  /// Creates a process-substitution part.
  ProcessSubstitutionPart(this.body, this.direction);

  /// The substituted script.
  final ScriptNode body;

  /// `input` (`<(...)`) or `output` (`>(...)`).
  final String direction;

  @override
  String get type => 'ProcessSubstitution';
}

// =============================================================================
// BRACE & TILDE EXPANSION
// =============================================================================

/// Brace expansion: `{a,b,c}` or `{1..10}`.
class BraceExpansionPart extends WordPart {
  /// Creates a brace-expansion part.
  BraceExpansionPart(this.items);

  /// The brace items.
  final List<BraceItem> items;

  @override
  String get type => 'BraceExpansion';
}

/// An item within a [BraceExpansionPart].
sealed class BraceItem {
  /// The discriminant string.
  String get type;
}

/// A literal word item within a brace expansion.
class BraceWordItem extends BraceItem {
  /// Creates a brace word item.
  BraceWordItem(this.word);

  /// The word.
  final WordNode word;

  @override
  String get type => 'Word';
}

/// A range item within a brace expansion (`{1..10}`).
class BraceRangeItem extends BraceItem {
  /// Creates a brace range item.
  BraceRangeItem(
    this.start,
    this.end, {
    this.step,
    this.startStr,
    this.endStr,
  });

  /// The range start (String or int).
  final Object start;

  /// The range end (String or int).
  final Object end;

  /// The optional step.
  final int? step;

  /// Original start string (for zero-padding).
  final String? startStr;

  /// Original end string (for zero-padding).
  final String? endStr;

  @override
  String get type => 'Range';
}

/// Tilde expansion: `~` or `~user`.
class TildeExpansionPart extends WordPart {
  /// Creates a tilde-expansion part.
  TildeExpansionPart(this.user);

  /// The user, or null for the current user.
  final String? user;

  @override
  String get type => 'TildeExpansion';
}

// =============================================================================
// GLOB
// =============================================================================

/// A glob pattern part (expanded during pathname expansion).
class GlobPart extends WordPart {
  /// Creates a glob part.
  GlobPart(this.pattern);

  /// The glob pattern.
  final String pattern;

  @override
  String get type => 'Glob';
}

// =============================================================================
// CONDITIONAL EXPRESSIONS (for [[ ]])
// =============================================================================

/// A conditional expression node (for `[[ ]]`).
sealed class ConditionalExpressionNode extends AstNode {}

/// A binary conditional `left OP right`.
class CondBinaryNode extends ConditionalExpressionNode {
  /// Creates a binary conditional node.
  CondBinaryNode(this.operator, this.left, this.right);

  /// The operator text.
  final String operator;

  /// The left word.
  final WordNode left;

  /// The right word.
  final WordNode right;

  @override
  String get type => 'CondBinary';
}

/// A unary conditional `OP operand`.
class CondUnaryNode extends ConditionalExpressionNode {
  /// Creates a unary conditional node.
  CondUnaryNode(this.operator, this.operand);

  /// The operator text.
  final String operator;

  /// The operand word.
  final WordNode operand;

  @override
  String get type => 'CondUnary';
}

/// A negation `! expr`.
class CondNotNode extends ConditionalExpressionNode {
  /// Creates a not node.
  CondNotNode(this.operand);

  /// The negated expression.
  final ConditionalExpressionNode operand;

  @override
  String get type => 'CondNot';
}

/// A conjunction `left && right`.
class CondAndNode extends ConditionalExpressionNode {
  /// Creates an and node.
  CondAndNode(this.left, this.right);

  /// The left expression.
  final ConditionalExpressionNode left;

  /// The right expression.
  final ConditionalExpressionNode right;

  @override
  String get type => 'CondAnd';
}

/// A disjunction `left || right`.
class CondOrNode extends ConditionalExpressionNode {
  /// Creates an or node.
  CondOrNode(this.left, this.right);

  /// The left expression.
  final ConditionalExpressionNode left;

  /// The right expression.
  final ConditionalExpressionNode right;

  @override
  String get type => 'CondOr';
}

/// A parenthesized conditional group.
class CondGroupNode extends ConditionalExpressionNode {
  /// Creates a group node.
  CondGroupNode(this.expression);

  /// The grouped expression.
  final ConditionalExpressionNode expression;

  @override
  String get type => 'CondGroup';
}

/// A bare word used as a conditional (truthy if non-empty).
class CondWordNode extends ConditionalExpressionNode {
  /// Creates a word node.
  CondWordNode(this.word);

  /// The word.
  final WordNode word;

  @override
  String get type => 'CondWord';
}

import 'dart:async' show StreamController;

import 'package:meta/meta.dart';

import '../../quill_delta.dart';
import '../common/structs/offset_value.dart';
import '../common/structs/segment_leaf_node.dart';

import '../editor/config/search_config.dart';
import '../editor/embed/embed_editor_builder.dart';
import '../rules/rule.dart';
import 'attribute.dart';
import 'history.dart';
import 'nodes/block.dart';
import 'nodes/container.dart';
import 'nodes/embeddable.dart';
import 'nodes/leaf.dart';
import 'nodes/line.dart';
import 'nodes/node.dart';
import 'structs/doc_change.dart';
import 'structs/history_changed.dart';
import 'style.dart';

/// The rich text document
class Document {
  /// Creates new empty document.
  Document() : _delta = Delta()..insert('\n') {
    loadDocument(_delta);
  }

  /// Creates new document from provided JSON `data`.
  Document.fromJson(List data) : _delta = _transform(Delta.fromJson(data)) {
    loadDocument(_delta);
  }

  /// Creates new document from provided `delta`.
  Document.fromDelta(Delta delta) : _delta = delta {
    loadDocument(delta);
  }

  /// Stores the plain text content of the entire document in memory for quick access.
  ///
  /// It acts as a cache to avoid repeatedly extracting or generating the plain text.
  @visibleForTesting
  @internal
  String? cachedPlainText;

  /// The root node of the document tree
  final Root _root = Root();

  Root get root => _root;

  /// Length of this document.
  int get length => _root.length;

  Delta _delta;

  /// Returns contents of this document as [Delta].
  Delta toDelta() => Delta.from(_delta);

  final Rules _rules = Rules.getInstance();

  void setCustomRules(List<Rule> customRules) {
    _rules.setCustomRules(customRules);
  }

  final StreamController<DocChange> documentChangeObserver =
      StreamController.broadcast();

  final History history = History();

  /// Stream of [DocChange]s applied to this document.
  Stream<DocChange> get changes => documentChangeObserver.stream;

  /// Inserts [data] in this document at specified [index].
  ///
  /// The `data` parameter can be either a String or an instance of
  /// [Embeddable].
  ///
  /// Applies heuristic rules before modifying this document and
  /// produces a change event with its source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta insert(int index, Object? data, {int replaceLength = 0}) {
    assert(index >= 0);
    assert(data is String || data is Embeddable);
    if (data is Embeddable) {
      data = data.toJson();
    } else if ((data as String).isEmpty) {
      return Delta();
    }

    final delta = _rules.apply(RuleType.insert, this, index,
        data: data, len: replaceLength);
    compose(delta, ChangeSource.local);
    return delta;
  }

  /// Deletes [length] of characters from this document starting at [index].
  ///
  /// This method applies heuristic rules before modifying this document and
  /// produces a [Change] with source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta delete(int index, int len) {
    assert(index >= 0 && len > 0);
    final delta = _rules.apply(RuleType.delete, this, index, len: len);
    if (delta.isNotEmpty) {
      compose(delta, ChangeSource.local);
    }
    return delta;
  }

  /// Replaces [length] of characters starting at [index] with [data].
  ///
  /// This method applies heuristic rules before modifying this document and
  /// produces a change event with its source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta replace(int index, int len, Object? data) {
    assert(index >= 0);
    assert(data is String || data is Embeddable || data is Delta);

    var delta = Delta();

    if (data is Delta) {
      // move to insertion point and add the inserted content
      if (index > 0) {
        delta.retain(index);
      }

      // remove any text we are replacing
      if (len > 0) {
        delta.delete(len);
      }

      // add the pasted content
      for (final op in data.operations) {
        delta.push(op);
      }

      compose(delta, ChangeSource.local);
    } else {
      final dataIsNotEmpty = (data is String) ? data.isNotEmpty : true;

      assert(dataIsNotEmpty || len > 0);

      // We have to insert before applying delete rules
      // Otherwise delete would be operating on stale document snapshot.
      if (dataIsNotEmpty) {
        delta = insert(index, data, replaceLength: len);
      }

      if (len > 0) {
        final deleteDelta = delete(index, len);
        delta = delta.compose(deleteDelta);
      }
    }

    return delta;
  }

  /// Formats segment of this document with specified [attribute].
  ///
  /// Applies heuristic rules before modifying this document and
  /// produces a change event with its source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  /// The returned [Delta] may be empty in which case this document remains
  /// unchanged and no change event is published to the [changes] stream.
  Delta format(int index, int len, Attribute? attribute) {
    assert(index >= 0 && len >= 0 && attribute != null);

    var delta = Delta();

    final formatDelta = _rules.apply(RuleType.format, this, index,
        len: len, attribute: attribute);
    if (formatDelta.isNotEmpty) {
      compose(formatDelta, ChangeSource.local);
      delta = delta.compose(formatDelta);
    }

    return delta;
  }

  /// Only attributes applied to all characters within this range are
  /// included in the result.
  /// Special case of no-selection at start of empty line: gets inline style(s) from preceding non-empty line.
  Style collectStyle(int index, int len) {
    var res = queryChild(index);
    if (res.node == null) {
      return const Style();
    }
    if (len > 0) {
      return (res.node as Line).collectStyle(res.offset, len);
    }
    //
    if (res.offset == 0) {
      final current = (res.node as Line).collectStyle(0, 0);
      //
      while ((res.node as Line).length == 1 && index > 0) {
        res = queryChild(--index);
      }
      // Get inline attributes from previous line (link does not cross line breaks)
      final prev = (res.node as Line).collectStyle(res.offset, 0);
      final attributes = <String, Attribute>{};
      for (final attr in prev.attributes.values) {
        if (attr.scope == AttributeScope.inline &&
            attr.key != Attribute.link.key) {
          attributes[attr.key] = attr;
        }
      }
      // Combine with block attributes from current line (exclude headers which apply only to the active line)
      for (final attr in current.attributes.values) {
        if (attr.scope == AttributeScope.block &&
            attr.key != Attribute.header.key) {
          attributes[attr.key] = attr;
        }
      }
      return Style.attr(attributes);
    }
    //
    final style = (res.node as Line).collectStyle(res.offset - 1, 0);
    final linkAttribute = style.attributes[Attribute.link.key];
    if (linkAttribute != null) {
      if ((res.node!.length - 1 == res.offset) ||
          (linkAttribute.value !=
              (res.node as Line)
                  .collectStyle(res.offset, len)
                  .attributes[Attribute.link.key]
                  ?.value)) {
        return style.removeAll({linkAttribute});
      }
    }
    return style;
  }

  /// Returns all styles and Embed for each node within selection
  List<OffsetValue> collectAllIndividualStyleAndEmbed(int index, int len) {
    final res = queryChild(index);
    return (res.node as Line)
        .collectAllIndividualStylesAndEmbed(res.offset, len);
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> collectAllStyles(int index, int len) {
    final res = queryChild(index);
    return (res.node as Line).collectAllStyles(res.offset, len);
  }

  /// Returns all styles for any character within the specified text range.
  List<OffsetValue<Style>> collectAllStylesWithOffset(int index, int len) {
    final res = queryChild(index);
    return (res.node as Line).collectAllStylesWithOffsets(res.offset, len);
  }

  // Store properties that are set in the editor config
  // to access them here to support search within embed objects.
  // See https://github.com/singerdmx/flutter-quill/pull/2090
  Iterable<EmbedBuilder>? _embedBuilders;
  EmbedBuilder? _unknownEmbedBuilder;
  QuillSearchConfig? _searchConfig;

  @visibleForTesting
  @internal
  Iterable<EmbedBuilder>? get embedBuilders => _embedBuilders;

  @visibleForTesting
  @internal
  EmbedBuilder? get unknownEmbedBuilder => _unknownEmbedBuilder;

  @visibleForTesting
  @internal
  QuillSearchConfig? get searchConfig => _searchConfig;

  @internal
  set searchConfig(QuillSearchConfig? searchConfig) =>
      _searchConfig = searchConfig;

  @internal
  set embedBuilders(Iterable<EmbedBuilder>? embedBuilders) =>
      _embedBuilders = embedBuilders;

  @internal
  set unknownEmbedBuilder(EmbedBuilder? unknownEmbedBuilder) =>
      _unknownEmbedBuilder = unknownEmbedBuilder;

  /// Returns plain text within the specified text range.
  String getPlainText(
    int index,
    int len, {
    @internal bool includeEmbeds = false,
  }) {
    final res = queryChild(index);
    return (res.node as Line).getPlainText(
      res.offset,
      len,
      embedBuilders: includeEmbeds ? _embedBuilders : null,
      unknownEmbedBuilder: includeEmbeds ? _unknownEmbedBuilder : null,
    );
  }

  /// Returns [Line] located at specified character [offset].
  ChildQuery queryChild(int offset) {
    // TODO: prevent user from moving caret after last line-break.
    final res = _root.queryChild(offset, true);
    if (res.node == null) {
      return res;
    }
    if (res.node is Line) {
      return res;
    }
    final block = res.node as Block;
    return block.queryChild(res.offset, true);
  }

  /// Search given [substring] in the whole document
  /// Supports [caseSensitive] and [wholeWord] options
  /// Returns correspondent offsets
  List<int> search(
    String substring, {
    bool caseSensitive = false,
    bool wholeWord = false,
  }) {
    final matches = <int>[];
    for (final node in _root.children) {
      if (node is Line) {
        _searchLine(
          substring,
          caseSensitive,
          wholeWord,
          _searchConfig?.searchEmbedMode ?? SearchEmbedMode.none,
          node,
          matches,
        );
      } else if (node is Block) {
        for (final line in Iterable.castFrom<dynamic, Line>(node.children)) {
          _searchLine(
            substring,
            caseSensitive,
            wholeWord,
            _searchConfig?.searchEmbedMode ?? SearchEmbedMode.none,
            line,
            matches,
          );
        }
      } else {
        throw StateError('Unreachable.');
      }
    }
    return matches;
  }

  void _searchLine(
    String substring,
    bool caseSensitive,
    bool wholeWord,
    SearchEmbedMode searchEmbedMode,
    Line line,
    List<int> matches,
  ) {
    var index = -1;
    final lineText = line.toPlainText();
    var pattern = RegExp.escape(substring);
    if (wholeWord) {
      pattern = r'\b' + pattern + r'\b';
    }
    final searchExpression = RegExp(pattern, caseSensitive: caseSensitive);
    while (true) {
      index = lineText.indexOf(searchExpression, index + 1);
      if (index < 0) {
        break;
      }
      matches.add(index + line.documentOffset);
    }
    //
    if (line.hasEmbed && searchEmbedMode != SearchEmbedMode.none) {
      Node? node = line.children.first;
      while (node != null) {
        if (node is Embed) {
          final ofs = node.offset;
          final embedText = switch (searchEmbedMode) {
            SearchEmbedMode.rawData => node.value.data.toString(),
            SearchEmbedMode.plainText => _embedSearchText(node),
            SearchEmbedMode.none => null,
          };
          //
          if (embedText?.contains(searchExpression) == true) {
            final documentOffset = line.documentOffset + ofs;
            final index = matches.indexWhere((e) => e > documentOffset);
            if (index < 0) {
              matches.add(documentOffset);
            } else {
              matches.insert(index, documentOffset);
            }
          }
        }
        node = node.next;
      }
    }
  }

  String? _embedSearchText(Embed node) {
    EmbedBuilder? builder;

    final embedBuilders = _embedBuilders;
    if (embedBuilders != null) {
      // Find the builder for this embed
      for (final b in embedBuilders) {
        if (b.key == node.value.type) {
          builder = b;
          break;
        }
      }
    }
    builder ??= _unknownEmbedBuilder;
    //  Get searchable text for this embed
    return builder?.toPlainText(node);
  }

  /// Given offset, find its leaf node in document
  SegmentLeafNode querySegmentLeafNode(int offset) {
    final result = queryChild(offset);
    if (result.node == null) {
      return const SegmentLeafNode(null, null);
    }

    final line = result.node as Line;
    final segmentResult = line.queryChild(result.offset, false);
    return SegmentLeafNode(line, segmentResult.node as Leaf?);
  }

  /// Composes [change] Delta into this document.
  ///
  /// Use this method with caution as it does not apply heuristic rules to the
  /// [change].
  ///
  /// It is callers responsibility to ensure that the [change] conforms to
  /// the document model semantics and can be composed with the current state
  /// of this document.
  ///
  /// In case the [change] is invalid, behavior of this method is unspecified.
  void compose(Delta delta, ChangeSource changeSource) {
    assert(!documentChangeObserver.isClosed);
    delta.trim();
    assert(delta.isNotEmpty);

    var offset = 0;
    delta = _transform(delta);
    final originalDelta = toDelta();
    for (final op in delta.toList()) {
      final style =
          op.attributes != null ? Style.fromJson(op.attributes) : null;

      if (op.isInsert) {
        // Must normalize data before inserting into the document, makes sure
        // that any embedded objects are converted into EmbeddableObject type.
        _root.insert(offset, _normalize(op.data), style);
      } else if (op.isDelete) {
        _root.delete(offset, op.length);
      } else if (op.attributes != null) {
        _root.retain(offset, op.length, style);
      }

      if (!op.isDelete) {
        offset += op.length!;
      }
    }
    try {
      _delta = _delta.compose(delta);
    } catch (e) {
      throw StateError('_delta compose failed');
    }
    assert(_delta == _root.toDelta(), 'Compose failed');
    cachedPlainText = null;
    final change = DocChange(originalDelta, delta, changeSource);
    documentChangeObserver.add(change);
    history.handleDocChange(change);
  }

  HistoryChanged undo() {
    cachedPlainText = null;
    return history.undo(this);
  }

  HistoryChanged redo() {
    cachedPlainText = null;
    return history.redo(this);
  }

  bool get hasUndo => history.hasUndo;

  bool get hasRedo => history.hasRedo;

  static Delta _transform(Delta delta) {
    final res = Delta();
    final ops = delta.toList();
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      res.push(op);
      _autoAppendNewlineAfterEmbeddable(i, ops, op, res, BlockEmbed.videoType);
    }
    return res;
  }

  static void _autoAppendNewlineAfterEmbeddable(
      int i, List<Operation> ops, Operation op, Delta res, String type) {
    final nextOpIsEmbed = i + 1 < ops.length &&
        ops[i + 1].isInsert &&
        ops[i + 1].data is Map &&
        (ops[i + 1].data as Map).containsKey(type);
    if (nextOpIsEmbed &&
        op.data is String &&
        (op.data as String).isNotEmpty &&
        !(op.data as String).endsWith('\n')) {
      res.push(Operation.insert('\n'));
    }
    // embed could be image or video
    final opInsertEmbed =
        op.isInsert && op.data is Map && (op.data as Map).containsKey(type);
    final nextOpIsLineBreak = i + 1 < ops.length &&
        ops[i + 1].isInsert &&
        ops[i + 1].data is String &&
        (ops[i + 1].data as String).startsWith('\n');
    if (opInsertEmbed && (i + 1 == ops.length - 1 || !nextOpIsLineBreak)) {
      // automatically append '\n' for embeddable
      res.push(Operation.insert('\n'));
    }
  }

  Object _normalize(Object? data) {
    if (data is String) {
      return data;
    }

    if (data is Embeddable) {
      return data;
    }
    return Embeddable.fromJson(data as Map<String, dynamic>);
  }

  void close() {
    documentChangeObserver.close();
    history.clear();
  }

  /// Returns plain text representation of this document.
  String toPlainText([
    Iterable<EmbedBuilder>? embedBuilders,
    EmbedBuilder? unknownEmbedBuilder,
  ]) =>
      cachedPlainText ??= _root.children
          .map((e) => e.toPlainText(embedBuilders, unknownEmbedBuilder))
          .join();

  @visibleForTesting
  @internal
  void loadDocument(Delta doc) {
    if (doc.isEmpty) {
      throw ArgumentError.value(
          doc.toString(), 'Document Delta cannot be empty.');
    }

    // assert((doc.last.data as String).endsWith('\n'));

    var offset = 0;
    for (final op in doc.toList()) {
      if (!op.isInsert) {
        throw ArgumentError.value(doc,
            'Document can only contain insert operations but ${op.key} found.');
      }
      final style =
          op.attributes != null ? Style.fromJson(op.attributes) : null;
      final data = _normalize(op.data);
      _root.insert(offset, data, style);
      offset += op.length!;
    }
    final node = _root.last;
    if (node is Line &&
        node.parent is! Block &&
        node.style.isEmpty &&
        _root.childCount > 1) {
      _root.remove(node);
    }
    cachedPlainText = null;
  }

  bool isEmpty() {
    if (root.children.length != 1) {
      return false;
    }

    final node = root.children.first;
    if (!node.isLast) {
      return false;
    }

    final delta = node.toDelta();
    return delta.length == 1 &&
        delta.first.data == '\n' &&
        delta.first.key == 'insert';
  }
}

/// Source of a [Change].
enum ChangeSource {
  /// Change originated from a local action. Typically triggered by user.
  local,

  /// Change originated from a remote action.
  remote,

  /// Silent change.
  silent;
}

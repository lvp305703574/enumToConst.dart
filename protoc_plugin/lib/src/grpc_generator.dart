// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of '../protoc.dart';

class GrpcServiceGenerator {
  final ServiceDescriptorProto _descriptor;

  /// The generator of the .pb.dart file that will contain this service.
  final FileGenerator fileGen;

  final int _serviceIndex;

  /// The message types needed directly by this service.
  ///
  /// The key is the fully qualified name.
  /// Populated by [resolve].
  final Map<String, MessageGenerator> _deps = {};

  /// Maps each undefined type to a string describing its location.
  ///
  /// Populated by [resolve].
  final Map<String, String> _undefinedDeps = {};

  /// Fully-qualified gRPC service name.
  late final String _fullServiceName;

  /// Dart class name for client stub.
  late final String _clientClassname;

  /// Dart class name for server stub.
  late final String _serviceClassname;

  /// List of gRPC methods.
  final List<_GrpcMethod> _methods = [];

  late final List<int> _serviceDescriptorPath = [
    ...fileGen.fieldPath,
    ClientApiGenerator.fileDescriptorServiceTag,
    _serviceIndex,
  ];

  GrpcServiceGenerator(this._descriptor, this.fileGen, this._serviceIndex) {
    final name = _descriptor.name;
    final package = fileGen.package;

    if (package.isNotEmpty) {
      _fullServiceName = '$package.$name';
    } else {
      _fullServiceName = name;
    }

    // avoid: ClientClient
    _clientClassname = name.endsWith('Client') ? name : '${name}Client';
    // avoid: ServiceServiceBase
    _serviceClassname =
        name.endsWith('Service') ? '${name}Base' : '${name}ServiceBase';
  }

  /// Finds all message types used by this service.
  ///
  /// Puts the types found in [_deps]. If a type name can't be resolved, puts it
  /// in [_undefinedDeps].
  /// Precondition: messages have been registered and resolved.
  void resolve(GenerationContext ctx) {
    for (final method in _descriptor.method) {
      _methods.add(_GrpcMethod(this, ctx, method));
    }
  }

  /// Adds a dependency on the given message type.
  ///
  /// If the type name can't be resolved, adds it to [_undefinedDeps].
  void _addDependency(GenerationContext ctx, String fqname, String location) {
    if (_deps.containsKey(fqname)) return; // Already added.

    final mg = ctx.getFieldType(fqname) as MessageGenerator?;
    if (mg == null) {
      _undefinedDeps[fqname] = location;
      return;
    }
    mg.checkResolved();
    _deps[mg.dottedName] = mg;
  }

  /// Adds dependencies of [generate] to [imports].
  ///
  /// For each .pb.dart file that the generated code needs to import,
  /// add its generator.
  void addImportsTo(Set<FileGenerator> imports) {
    for (final mg in _deps.values) {
      imports.add(mg.fileGen);
    }
  }

  /// Returns the Dart class name to use for a message type.
  ///
  /// Throws an exception if it can't be resolved.
  String _getDartClassName(String fqName) {
    final generator = _deps[fqName];
    if (generator == null) {
      final location = _undefinedDeps[fqName];
      // TODO(nichite): Throw more actionable error.
      throw 'FAILURE: Unknown type reference ($fqName) for $location';
    }

    return '${generator.importPrefix(context: fileGen)}.${generator.classname}';
  }

  void generate(IndentingWriter out) {
    _generateClient(out);
    out.println();
    _generateService(out);
  }

  void _generateClient(IndentingWriter out) {
    final commentBlock = fileGen.commentBlock(_serviceDescriptorPath);
    if (commentBlock != null) {
      out.println(commentBlock);
    }
    if (_descriptor.options.deprecated) {
      out.println(
        "@$coreImportPrefix.Deprecated('This service is deprecated')",
      );
    }
    out.println("@$protobufImportPrefix.GrpcServiceName('$_fullServiceName')");
    out.addBlock('class $_clientClassname extends $_client {', '}', () {
      // Look for and generate default_host info.
      final defaultHost = _descriptor.options.defaultHost;
      if (defaultHost != null) {
        out.println('/// The hostname for this service.');
        out.println("static const $_string defaultHost = '$defaultHost';");
        out.println();
      }

      // Look for and generate oauth_scopes info.
      final oauthScopes = _descriptor.options.oauthScopes;
      if (oauthScopes != null) {
        out.println('/// OAuth scopes needed for the client.');
        out.println('static const $_list<$_string> oauthScopes = [');
        for (final scope in oauthScopes.split(',')) {
          out.println("  '$scope',");
        }
        out.println('];');
        out.println();
      }

      // generate the constructor
      out.println(
        '$_clientClassname(super.channel, {super.options, super.interceptors});',
      );

      // generate the service call methods
      for (var i = 0; i < _methods.length; i++) {
        _methods[i].generateClientStub(out, this, i);
      }

      // generate the method descriptors
      out.println();
      if (_methods.isNotEmpty) {
        out.println('  // method descriptors');
        out.println();

        for (final method in _methods) {
          method.generateClientMethodDescriptor(out);
        }
      }
    });
  }

  void _generateService(IndentingWriter out) {
    out.println("@$protobufImportPrefix.GrpcServiceName('$_fullServiceName')");
    out.addBlock(
      'abstract class $_serviceClassname extends $_service {',
      '}',
      () {
        out.println(
          "$coreImportPrefix.String get \$name => '$_fullServiceName';",
        );
        out.println();
        out.addBlock('$_serviceClassname() {', '}', () {
          for (final method in _methods) {
            method.generateServiceMethodRegistration(out);
          }
        });
        out.println();
        for (final method in _methods) {
          if (!method._clientStreaming) {
            method.generateServiceMethodPreamble(out);
            out.println();
          }
          method.generateServiceMethodStub(out);
          out.println();
        }
      },
    );
  }

  static final String _callOptions = '$grpcImportPrefix.CallOptions';
  static final String _client = '$grpcImportPrefix.Client';
  static final String _service = '$grpcImportPrefix.Service';
  static final String _list = '$coreImportPrefix.List';
  static final String _string = '$coreImportPrefix.String';
}

class _GrpcMethod {
  final String _grpcName;
  final String _dartName;
  final String _serviceName;

  final bool _clientStreaming;
  final bool _serverStreaming;

  final String _requestType;
  final String _responseType;

  final String _argumentType;
  final String _clientReturnType;
  final String _serverReturnType;

  final bool _deprecated;

  _GrpcMethod._(
    this._grpcName,
    this._dartName,
    this._serviceName,
    this._clientStreaming,
    this._serverStreaming,
    this._requestType,
    this._responseType,
    this._argumentType,
    this._clientReturnType,
    this._serverReturnType,
    this._deprecated,
  );

  factory _GrpcMethod(
    GrpcServiceGenerator service,
    GenerationContext ctx,
    MethodDescriptorProto method,
  ) {
    final grpcName = method.name;
    final dartName = lowerCaseFirstLetter(grpcName);

    final clientStreaming = method.clientStreaming;
    final serverStreaming = method.serverStreaming;

    service._addDependency(ctx, method.inputType, 'input type of $grpcName');
    service._addDependency(ctx, method.outputType, 'output type of $grpcName');

    final requestType = service._getDartClassName(method.inputType);
    final responseType = service._getDartClassName(method.outputType);

    final argumentType =
        clientStreaming ? '$_stream<$requestType>' : requestType;
    final clientReturnType =
        serverStreaming
            ? '$_responseStream<$responseType>'
            : '$_responseFuture<$responseType>';
    final serverReturnType =
        serverStreaming ? '$_stream<$responseType>' : '$_future<$responseType>';

    final deprecated = method.options.deprecated;

    return _GrpcMethod._(
      grpcName,
      dartName,
      service._fullServiceName,
      clientStreaming,
      serverStreaming,
      requestType,
      responseType,
      argumentType,
      clientReturnType,
      serverReturnType,
      deprecated,
    );
  }

  void generateClientMethodDescriptor(IndentingWriter out) {
    out.println(
      'static final _\$$_dartName = $_clientMethod<$_requestType, $_responseType>(',
    );
    out.println('    \'/$_serviceName/$_grpcName\',');
    out.println('    ($_requestType value) => value.writeToBuffer(),');
    out.println('    $_responseType.fromBuffer);');
  }

  List<int> _methodDescriptorPath(GrpcServiceGenerator generator, int index) {
    return [
      ...generator._serviceDescriptorPath,
      ClientApiGenerator.serviceDescriptorMethodTag,
      index,
    ];
  }

  void generateClientStub(
    IndentingWriter out,
    GrpcServiceGenerator serviceGenerator,
    int methodIndex,
  ) {
    out.println();
    final commentBlock = serviceGenerator.fileGen.commentBlock(
      _methodDescriptorPath(serviceGenerator, methodIndex),
    );
    if (commentBlock != null) {
      out.println(commentBlock);
    }
    if (_deprecated) {
      out.println(
        '@$coreImportPrefix.Deprecated(\'This method is deprecated\')',
      );
    }
    out.addBlock(
      '$_clientReturnType $_dartName($_argumentType request, {${GrpcServiceGenerator._callOptions}? options,}) {',
      '}',
      () {
        if (_clientStreaming && _serverStreaming) {
          out.println(
            'return \$createStreamingCall(_\$$_dartName, request, options: options);',
          );
        } else if (_clientStreaming && !_serverStreaming) {
          out.println(
            'return \$createStreamingCall(_\$$_dartName, request, options: options).single;',
          );
        } else if (!_clientStreaming && _serverStreaming) {
          out.println(
            'return \$createStreamingCall(_\$$_dartName, $_stream.fromIterable([request]), options: options);',
          );
        } else {
          out.println(
            'return \$createUnaryCall(_\$$_dartName, request, options: options);',
          );
        }
      },
    );
  }

  void generateServiceMethodRegistration(IndentingWriter out) {
    out.println('\$addMethod($_serviceMethod<$_requestType, $_responseType>(');
    out.println('    \'$_grpcName\',');
    out.println('    $_dartName${_clientStreaming ? '' : '_Pre'},');
    out.println('    $_clientStreaming,');
    out.println('    $_serverStreaming,');
    out.println(
      '    ($coreImportPrefix.List<$coreImportPrefix.int> value) => $_requestType.fromBuffer(value),',
    );
    out.println('    ($_responseType value) => value.writeToBuffer()));');
  }

  void generateServiceMethodPreamble(IndentingWriter out) {
    out.addBlock(
      '$_serverReturnType ${_dartName}_Pre($_serviceCall \$call, $_future<$_requestType> \$request) async${_serverStreaming ? '*' : ''} {',
      '}',
      () {
        if (_serverStreaming) {
          out.println('yield* $_dartName(\$call, await \$request);');
        } else {
          out.println('return $_dartName(\$call, await \$request);');
        }
      },
    );
  }

  void generateServiceMethodStub(IndentingWriter out) {
    out.println(
      '$_serverReturnType $_dartName($_serviceCall call, $_argumentType request);',
    );
  }

  static final String _serviceCall = '$grpcImportPrefix.ServiceCall';
  static final String _serviceMethod = '$grpcImportPrefix.ServiceMethod';
  static final String _clientMethod = '$grpcImportPrefix.ClientMethod';
  static final String _future = '$asyncImportPrefix.Future';
  static final String _stream = '$asyncImportPrefix.Stream';
  static final String _responseFuture = '$grpcImportPrefix.ResponseFuture';
  static final String _responseStream = '$grpcImportPrefix.ResponseStream';
}

extension on ServiceOptions {
  String? get defaultHost => getExtension(Client.defaultHost) as String?;

  String? get oauthScopes => getExtension(Client.oauthScopes) as String?;
}

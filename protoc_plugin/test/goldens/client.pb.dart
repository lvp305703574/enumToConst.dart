class TestApi {
  final $pb.RpcClient _client;

  TestApi(this._client);

  $async.Future<SomeReply> aMethod(
    $pb.ClientContext? ctx,
    SomeRequest request,
  ) => _client.invoke<SomeReply>(ctx, 'Test', 'AMethod', request, SomeReply());
  $async.Future<$0.AnotherReply> anotherMethod(
    $pb.ClientContext? ctx,
    $0.EmptyMessage request,
  ) => _client.invoke<$0.AnotherReply>(
    ctx,
    'Test',
    'AnotherMethod',
    request,
    $0.AnotherReply(),
  );
}

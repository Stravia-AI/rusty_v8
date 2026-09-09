#[test]
fn clearing_embedder_callback_restores_default_and_page_stack_formatting() {
  let platform = v8::new_default_platform(0, false).make_shared();
  v8::V8::initialize_platform(platform);
  v8::V8::initialize();
  {
    let isolate = &mut v8::Isolate::new(Default::default());
    v8::scope!(let scope, isolate);
    let context = v8::Context::new(scope, Default::default());
    let scope = &mut v8::ContextScope::new(scope, context);
    scope.set_prepare_stack_trace_callback(callback);
    assert_eq!(evaluate(scope, "new Error('boom').stack"), "42");
    scope.clear_prepare_stack_trace_callback();
    assert!(
      evaluate(scope, "new Error('boom').stack").starts_with("Error: boom")
    );
    evaluate(scope, "Error.prepareStackTrace = () => 73");
    scope.set_prepare_stack_trace_callback(callback);
    assert_eq!(evaluate(scope, "new Error('boom').stack"), "42");
    scope.clear_prepare_stack_trace_callback();
    assert_eq!(evaluate(scope, "new Error('boom').stack"), "73");
  }
  unsafe { v8::V8::dispose() };
  v8::V8::dispose_platform();
}

fn evaluate(scope: &mut v8::PinScope<'_, '_>, source: &str) -> String {
  let source = v8::String::new(scope, source).unwrap();
  let script = v8::Script::compile(scope, source, None).unwrap();
  script.run(scope).unwrap().to_rust_string_lossy(scope)
}

fn callback<'s>(
  scope: &mut v8::PinScope<'s, '_>,
  _error: v8::Local<v8::Value>,
  _sites: v8::Local<v8::Array>,
) -> v8::Local<'s, v8::Value> {
  v8::Integer::new(scope, 42).into()
}

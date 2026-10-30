#!/bin/sh
set -eu
dart format \
  lib/services/backend_api_config.dart \
  lib/services/backend_ai_service.dart \
  lib/services/backend_sse_decoder.dart \
  lib/controllers/chat_controller.dart \
  lib/services/conversation_repository.dart \
  test/backend_ai_service_test.dart \
  test/phase3a_text_flow_test.dart \
  test/conversation_repository_test.dart \
  test/support/fake_chat_dependencies.dart

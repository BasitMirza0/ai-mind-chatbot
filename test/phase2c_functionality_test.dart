import 'dart:async';
import 'package:ai_chatbot/controllers/chat_controller.dart';
import 'package:ai_chatbot/models/conversation.dart';
import 'package:ai_chatbot/screens/chat_screen.dart';
import 'package:ai_chatbot/screens/home_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/widgets/profile_avatar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_chat_dependencies.dart';

class PendingPhoto extends ImageProvider<PendingPhoto> {
  final result=Completer<ImageInfo>();
  @override Future<PendingPhoto> obtainKey(ImageConfiguration configuration)=>SynchronousFuture(this);
  @override ImageStreamCompleter loadImage(PendingPhoto key, ImageDecoderCallback decode)=>OneFrameImageStreamCompleter(result.future);
}
void main() {
  testWidgets('avatar loads supplied photo; missing/invalid/failed photos use fallback', (tester) async {
    final pending=PendingPhoto();
    Widget avatar(String? url,{ImageProvider? image})=>MaterialApp(home:ProfileAvatar(uid:'one',name:'Alex',photoUrl:url,imageProvider:(_)=>image??pending));
    await tester.pumpWidget(avatar(null));expect(find.text('A'),findsOneWidget);expect(find.byType(Image),findsNothing);
    await tester.pumpWidget(avatar('file:///private'));expect(find.byType(Image),findsNothing);
    await tester.pumpWidget(avatar('https://example.com/avatar'));expect(find.text('A'),findsOneWidget);
    pending.result.completeError(StateError('offline'));await tester.pump();expect(find.text('A'),findsOneWidget);expect(tester.takeException(),isNull);
    await tester.pumpWidget(avatar('https://example.com/available',image:const AssetImage('assets/images/robot.png')));
    await tester.runAsync(()=>precacheImage(const AssetImage('assets/images/robot.png'),tester.element(find.byType(ProfileAvatar))));
    await tester.pumpAndSettle();expect(find.text('A'),findsNothing);expect(find.byType(RawImage),findsOneWidget);
  });
  testWidgets('profile changes account identity and clears photo on logout', (tester) async {
    final session=FakeSession()..photo='https://example.com/one';final repository=FakeRepository();addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home:HomeScreen(session:session,repository:repository)));await tester.pump();
    var avatar=tester.widget<ProfileAvatar>(find.byType(ProfileAvatar));expect(avatar.uid,'alice');expect(avatar.photoUrl,session.photo);
    session.photo='https://example.com/two';session.displayName='Blair';session.change('bob');await tester.pump();
    avatar=tester.widget<ProfileAvatar>(find.byType(ProfileAvatar));expect(avatar.uid,'bob');expect(avatar.photoUrl,'https://example.com/two');
    expect(tester.widget<Image>(find.descendant(of:find.byType(ProfileAvatar),matching:find.byType(Image))).gaplessPlayback,false);
    session.change(null);await tester.pump();expect(find.descendant(of:find.byType(ProfileAvatar),matching:find.byType(Image)),findsNothing);
  });
  for(final size in [const Size(360,800),const Size(393,852),const Size(430,932),const Size(852,393)]) {
    for(final scale in [1.0,2.0]) {
      testWidgets('composer controls remain above real viewInsets $size scale $scale', (tester) async {
        tester.view.physicalSize=size;tester.view.devicePixelRatio=1;
        addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);addTearDown(tester.view.resetViewInsets);
        final session=FakeSession();final repo=FakeRepository();final ai=FakeAi();
        final controller=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);
        addTearDown((){controller.dispose();session.dispose();ai.close();});
        await tester.pumpWidget(MaterialApp(theme:AppTheme.light,builder:(ctx,child)=>MediaQuery(data:MediaQuery.of(ctx).copyWith(textScaler:TextScaler.linear(scale)),child:child!),home:ChatScreen(session:session,controller:controller)));
        await tester.pumpAndSettle();await tester.enterText(find.byKey(const Key('chat-input')),'A draft\nwith multiple\nlines to keep');
        for(final inset in [size.height<500?180.0:300.0,0.0,size.height<500?200.0:340.0]) {
          tester.view.viewInsets=FakeViewPadding(bottom:inset);await tester.pumpAndSettle();
          for(final finder in [find.byKey(const Key('chat-input')),find.byTooltip('Send message'),find.byTooltip('Dictate message'),find.byTooltip('Attach image for analysis')]) {
            final rect=tester.getRect(finder);expect(rect.bottom,lessThanOrEqualTo(size.height-inset+.1));
            expect(finder.hitTestable(),findsOneWidget);
          }
          expect(controller.conversation.draft,'A draft\nwith multiple\nlines to keep');expect(tester.takeException(),isNull);
        }
        tester.view.physicalSize=Size(size.height,size.width);tester.view.viewInsets=FakeViewPadding(bottom:size.width<500?180:300);await tester.pumpAndSettle();expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('History opens the owned list; search and selection close only drawer', (tester) async {
    final session=FakeSession();final repo=FakeRepository()..summaries=[const ConversationSummary('one','First idea'),const ConversationSummary('two','Second idea')];
    repo.records['two']=[ChatMessage(id:'m',role:'user',text:'Saved second message',saved:true)];
    final ai=FakeAi();final controller=ChatController(ai:ai,repository:repo,currentUid:()=>session.uid);
    addTearDown((){controller.dispose();session.dispose();ai.close();});
    await tester.pumpWidget(MaterialApp(home:ChatScreen(session:session,controller:controller)));await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open conversation menu'));await tester.pumpAndSettle();expect(find.text('First idea'),findsOneWidget);
    await tester.enterText(find.byKey(const Key('drawer-search')),'Second');await tester.pumpAndSettle();
    expect(find.text('First idea'),findsNothing);await tester.tap(find.text('Second idea'));await tester.pumpAndSettle();
    expect(controller.conversation.id,'two');expect(find.text('Saved second message'),findsWidgets);expect(find.text('Conversations').hitTestable(),findsNothing);
    expect(find.byType(ChatScreen),findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('keyboard resizes messages without pulling a reader to the bottom or losing selection',(t)async {
    t.view.physicalSize=const Size(393,852);t.view.devicePixelRatio=1;
    addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetViewInsets);
    final session=FakeSession();final ai=FakeAi();final chat=ChatController(ai:ai,repository:FakeRepository(),currentUid:()=>session.uid);
    addTearDown((){chat.dispose();session.dispose();ai.close();});
    chat.conversation.messages.addAll(List.generate(40,(i)=>ChatMessage(id:'m$i',role:i.isEven?'user':'bot',text:'Thought $i. A message worth keeping.',saved:true)));
    await t.pumpWidget(MaterialApp(home:ChatScreen(session:session,controller:chat)));await t.pumpAndSettle();
    final list=find.byType(ListView).first;final scroll=t.widget<ListView>(list).controller!;
    scroll.jumpTo(150);await t.pumpAndSettle();final oldHeight=t.getSize(list).height;
    await t.enterText(find.byKey(const Key('chat-input')),'Keep this selected draft');
    final editable=t.widget<EditableText>(find.byType(EditableText).first);
    editable.controller.selection=const TextSelection(baseOffset:5,extentOffset:9);
    t.view.viewInsets=const FakeViewPadding(bottom:300);await t.pumpAndSettle();
    expect(t.getSize(list).height,lessThan(oldHeight));expect(scroll.offset,closeTo(150,1));
    chat.streamingText.value='A late chunk';await t.pumpAndSettle();expect(scroll.offset,closeTo(150,1));
    t.view.resetViewInsets();await t.pumpAndSettle();expect(editable.controller.selection,const TextSelection(baseOffset:5,extentOffset:9));
    expect(chat.conversation.draft,'Keep this selected draft');expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

}

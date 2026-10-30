import {before, after, beforeEach, test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {doc, collection, getDoc, getDocs, setDoc, updateDoc, deleteDoc, serverTimestamp, query, orderBy, limit, startAfter, Timestamp, runTransaction} from 'firebase/firestore';

// Fail closed: never accidentally run authorization tests against a live project.
if (process.env.FIRESTORE_EMULATOR_HOST !== '127.0.0.1:8080') {
  throw new Error('Use npm run test:emulator; only the loopback demo emulator is allowed.');
}
let env;
const chatPath = 'users/alice/chats/chat-1';
const messagePath = `${chatPath}/messages/message-1`;
const claims = {firebase: {sign_in_provider: 'password'}};
const asUser = uid => env.authenticatedContext(uid, claims).firestore();
const chat = () => ({title: 'Example', type: 'chat', createdAt: serverTimestamp(), updatedAt: serverTimestamp()});
const message = () => ({role: 'user', text: 'Hello', timestamp: serverTimestamp()});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ai-mind',
    firestore: {host: '127.0.0.1', port: 8080,
      rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8')},
  });
});
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), chatPath), chat());
    await setDoc(doc(context.firestore(), messagePath), message());
  });
});
after(async () => { if (env) await env.cleanup(); });

test('owner can read/list chats and messages', async () => {
  const db = asUser('alice');
  await assertSucceeds(getDoc(doc(db, chatPath)));
  await assertSucceeds(getDocs(collection(db, 'users/alice/chats')));
  await assertSucceeds(getDocs(collection(db, `${chatPath}/messages`)));
});
test('other user cannot read or list another user’s data', async () => {
  const db = asUser('bob');
  await assertFails(getDoc(doc(db, chatPath)));
  await assertFails(getDoc(doc(db, messagePath)));
  await assertFails(getDocs(collection(db, 'users/alice/chats')));
  await assertFails(getDocs(collection(db, `${chatPath}/messages`)));
});
test('other user cannot create, modify, overwrite or delete another user’s data', async () => {
  const db = asUser('bob');
  await assertFails(setDoc(doc(db, 'users/alice/chats/new'), chat()));
  await assertFails(setDoc(doc(db, `${chatPath}/messages/new`), message()));
  await assertFails(setDoc(doc(db, chatPath), chat()));
  await assertFails(updateDoc(doc(db, chatPath), {title: 'Hijacked'}));
  await assertFails(updateDoc(doc(db, messagePath), {text: 'Changed'}));
  await assertFails(deleteDoc(doc(db, messagePath)));
  await assertFails(deleteDoc(doc(db, chatPath)));
});
test('unauthenticated and anonymous clients are denied', async () => {
  const databases = [env.unauthenticatedContext().firestore(),
    env.authenticatedContext('alice', {firebase: {sign_in_provider: 'anonymous'}}).firestore()];
  for (const db of databases) {
    await assertFails(getDoc(doc(db, chatPath)));
    await assertFails(setDoc(doc(db, 'users/alice/chats/new'), chat()));
    await assertFails(deleteDoc(doc(db, messagePath)));
  }
});
test('owner can use the existing create/append/rename/timestamp/delete flow', async () => {
  const db = asUser('alice');
  await assertSucceeds(setDoc(doc(db, 'users/alice/chats/new'), chat()));
  await assertSucceeds(setDoc(doc(db, 'users/alice/chats/new/messages/new'), message()));
  await assertSucceeds(updateDoc(doc(db, chatPath), {title: 'Renamed', updatedAt: serverTimestamp()}));
  await assertSucceeds(deleteDoc(doc(db, messagePath)));
  await assertSucceeds(deleteDoc(doc(db, chatPath)));
});
test('legacy chat without type remains readable and renameable', async () => {
  await env.withSecurityRulesDisabled(async context => {
    const old = chat(); delete old.type;
    await setDoc(doc(context.firestore(), chatPath), old);
  });
  const db = asUser('alice');
  await assertSucceeds(getDoc(doc(db, chatPath)));
  await assertSucceeds(updateDoc(doc(db, chatPath), {title: 'Legacy renamed'}));
});
test('schema escalation, timestamp forgery, historical edits and orphan messages are denied', async () => {
  const db = asUser('alice');
  await assertFails(setDoc(doc(db, 'users/alice/chats/bad'), {...chat(), admin: true}));
  await assertFails(setDoc(doc(db, 'users/alice/chats/bad'), {...chat(), type: 'admin'}));
  await assertFails(updateDoc(doc(db, chatPath), {createdAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(db, chatPath), {owner: 'bob'}));
  await assertFails(updateDoc(doc(db, messagePath), {text: 'Changed'}));
  await assertFails(setDoc(doc(db, `${chatPath}/messages/bad`), {...message(), role: 'system'}));
  await assertFails(setDoc(doc(db, `${chatPath}/messages/bad`), {...message(), text: ''}));
  await assertFails(setDoc(doc(db, 'users/alice/chats/missing/messages/new'), message()));
  await assertFails(setDoc(doc(db, 'users/alice'), {admin: true}));
});

// Bounded sidebar queries run under client rules, not the Admin SDK.
test('owned timestamp pagination is ordered, bounded and denied cross-account', async () => {
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    for (let i = 0; i < 6; i++) {
      const at = Timestamp.fromMillis(1000000 + i * 1000);
      await setDoc(doc(db, `users/alice/chats/page-${i}`), {title: `Stored title ${i}`, type: 'chat', createdAt: at, updatedAt: at});
    }
  });
  const db = asUser('alice');
  const first = await assertSucceeds(getDocs(query(collection(db, 'users/alice/chats'), orderBy('updatedAt', 'desc'), limit(3))));
  const second = await assertSucceeds(getDocs(query(collection(db, 'users/alice/chats'), orderBy('updatedAt', 'desc'), startAfter(first.docs.at(-1)), limit(3))));
  const combined = [...first.docs, ...second.docs];
  if (first.size !== 3 || second.size !== 3 || new Set(combined.map(d => d.id)).size !== 6) throw new Error('Pagination duplicated or skipped the expected page size');
  for (let i = 1; i < combined.length; i++) {
    if (combined[i - 1].data().updatedAt.toMillis() < combined[i].data().updatedAt.toMillis()) throw new Error('History is not ordered');
  }
  await assertFails(getDocs(query(collection(asUser('bob'), 'users/alice/chats'), orderBy('updatedAt', 'desc'), limit(3))));
});
test('stable message create/retry transaction preserves immutable messages for Google identity', async () => {
  const db = env.authenticatedContext('alice', {firebase: {sign_in_provider: 'google.com'}}).firestore();
  const ref = doc(db, `${chatPath}/messages/stable-answer`);
  for (let i = 0; i < 2; i++) {
    await assertSucceeds(runTransaction(db, async tx => {
      const existing = await tx.get(ref);
      if (!existing.exists()) {
        tx.set(ref, {role: 'bot', text: 'A saved answer', timestamp: serverTimestamp()});
        tx.update(doc(db, chatPath), {updatedAt: serverTimestamp()});
      }
    }));
  }
  const saved = await assertSucceeds(getDoc(ref));
  if (saved.data().text !== 'A saved answer') throw new Error('Saved response changed');
  await assertFails(updateDoc(ref, {text: 'Overwrite'}));
});

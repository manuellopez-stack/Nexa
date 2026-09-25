// Loader de Node SOLO para tests: reemplaza @supabase/supabase-js y openai
// por los mocks en memoria de esta carpeta. Se activa con
//   node --import ./test/support/register-mocks.mjs --test "test/*.test.mjs"
const MOCKS = {
  "@supabase/supabase-js": new URL("./supabase-mock.mjs", import.meta.url).href,
  openai: new URL("./openai-mock.mjs", import.meta.url).href,
};

export async function resolve(specifier, context, nextResolve) {
  if (MOCKS[specifier]) return { url: MOCKS[specifier], shortCircuit: true };
  return nextResolve(specifier, context);
}

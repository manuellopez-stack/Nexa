// Reemplazo de "openai" SOLO para tests: cualquier llamada a la IA falla al
// instante (sin red), igual que si la API no respondiera. Un test puede
// encolar respuestas de responses.create en `queuedResponses` (se consumen en
// orden; con la cola vacía vuelve a fallar).
export const queuedResponses = [];

export default class OpenAI {
  constructor() {
    const fail = async () => {
      throw new Error("openai-mock: sin IA en los tests");
    };
    this.responses = {
      create: async () => (queuedResponses.length ? queuedResponses.shift() : fail()),
    };
    this.chat = { completions: { create: fail } };
  }
}

// Reemplazo de "openai" SOLO para tests: cualquier llamada a la IA falla al
// instante (sin red), igual que si la API no respondiera.
export default class OpenAI {
  constructor() {
    const fail = async () => {
      throw new Error("openai-mock: sin IA en los tests");
    };
    this.responses = { create: fail };
    this.chat = { completions: { create: fail } };
  }
}

-- Informe imprimible: guardar el PDF original de cada documento.
--
-- documents.pdf_path = ruta del PDF dentro del bucket privado de Storage
-- "clinical-documents": <clinic_id>/<patient_id>/<uuid>.pdf. Null = el
-- documento se guardó antes de este cambio (o su PDF no se pudo guardar):
-- GET /patients/:id/documents/:filename/pdf responde 404.
--
-- El bucket lo crea el backend al arrancar si no existe (privado, solo PDF,
-- 10 MB). Si se prefiere crearlo a mano, este es el equivalente:
--
--   insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
--   values ('clinical-documents', 'clinical-documents', false, 10485760, array['application/pdf'])
--   on conflict (id) do nothing;
--
-- No hacen falta políticas de Storage: solo el backend (service role) lee y
-- escribe ahí; la app nunca recibe URLs del bucket.

alter table public.documents
  add column if not exists pdf_path text;

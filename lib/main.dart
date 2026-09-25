import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'core/nexa_colors.dart';
import 'screens/dashboard_page.dart';
import 'services/api_service.dart';

void main() {
  final inviteLink = _extractInviteAccessToken();
  runApp(NexaApp(
    inviteAccessToken: inviteLink?.accessToken,
    isPasswordRecovery: inviteLink?.isRecovery ?? false,
  ));
}

// El link del correo de invitación (ver /staff/invite en server.mjs) redirige
// a la app web como https://.../#access_token=...&refresh_token=...&type=invite
// -- Supabase pone esos datos en el fragmento de la URL, no en query params.
// El correo de recuperar contraseña (ver /auth/forgot-password) hace lo mismo
// pero con type=recovery.
// Solo aplica a la versión web: en las otras plataformas Uri.base no refleja
// una URL de navegador, así que ahí se ignora.
({String accessToken, bool isRecovery})? _extractInviteAccessToken() {
  if (!kIsWeb) return null;

  final fragment = Uri.base.fragment;
  if (fragment.isEmpty) return null;

  final params = Uri.splitQueryString(fragment);
  final type = params['type'];
  if (type != 'invite' && type != 'recovery') return null;

  final token = params['access_token'];
  if (token == null || token.isEmpty) return null;
  return (accessToken: token, isRecovery: type == 'recovery');
}

class NexaApp extends StatelessWidget {
  const NexaApp({
    super.key,
    this.inviteAccessToken,
    this.isPasswordRecovery = false,
  });

  final String? inviteAccessToken;
  final bool isPasswordRecovery;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Imagenda',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: NexaColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: NexaColors.primary,
          primary: NexaColors.primary,
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: inviteAccessToken != null
          ? CreatePasswordPage(
              accessToken: inviteAccessToken!,
              isRecovery: isPasswordRecovery,
            )
          : const WelcomePage(),
    );
  }
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/imagenda_logo.png',
                  height: 72,
                ),
                const SizedBox(height: 28),
                const Text(
                  'Gestión clínica inteligente,\ntodo en un solo sistema.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.45,
                    color: NexaColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 42),
                SizedBox(
                  width: 220,
                  height: 56,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LoginPage(),
                        ),
                      );
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: NexaColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Comenzar',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.successMessage});

  final String? successMessage;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool get canSubmit =>
      emailController.text.trim().isNotEmpty &&
      passwordController.text.isNotEmpty &&
      !_isLoading;

  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;
  late final String? _success = widget.successMessage;

  @override
  void initState() {
    super.initState();
    emailController.addListener(_refresh);
    passwordController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!canSubmit) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ApiService.login(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DashboardPage()),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible iniciar sesión. Intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(
        initialEmail: emailController.text.trim(),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: NexaColors.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: NexaColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: NexaColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(
          color: NexaColors.primary,
          width: 2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Acceso a Imagenda',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: NexaColors.textPrimary,
          ),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Container(
              padding: const EdgeInsets.all(36),
              decoration: BoxDecoration(
                color: NexaColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: NexaColors.border),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 32,
                    offset: Offset(0, 14),
                    color: Color(0x140F172A),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/images/imagenda_logo.png',
                      height: 44,
                    ),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Bienvenido',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: NexaColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Ingresa a tu espacio de trabajo',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NexaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 30),
                  if (_success != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _success,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF166534),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: emailController,
                    textInputAction: TextInputAction.next,
                    decoration: _inputDecoration(
                      label: 'Correo electrónico',
                      icon: Icons.mail_outline,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: passwordController,
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _login(),
                    decoration: _inputDecoration(
                      label: 'Contraseña',
                      icon: Icons.lock_outline,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF991B1B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: canSubmit ? _login : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: NexaColors.primary,
                        disabledBackgroundColor: const Color(0xFFE2E8F0),
                        disabledForegroundColor: const Color(0xFF94A3B8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Ingresar',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: _isLoading ? null : _showForgotPasswordDialog,
                      child: const Text('¿Olvidaste tu contraseña?'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Diálogo "Recuperar contraseña" del LoginPage. El backend responde lo mismo
// exista o no la cuenta, así que tras enviar solo se muestra el aviso genérico.
class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final emailController = TextEditingController(text: widget.initialEmail);

  bool _isSending = false;
  bool _sent = false;
  String? _error;

  bool get canSubmit => emailController.text.trim().isNotEmpty && !_isSending;

  @override
  void initState() {
    super.initState();
    emailController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!canSubmit) return;

    setState(() {
      _isSending = true;
      _error = null;
    });

    try {
      await ApiService.forgotPassword(emailController.text.trim());
      if (mounted) setState(() => _sent = true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible enviar el enlace. Intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return AlertDialog(
        title: const Text('Recuperar contraseña'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'Si el correo está registrado, te enviamos un enlace para crear '
            'una nueva contraseña. Revisa también la carpeta de spam.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendido'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Recuperar contraseña'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: emailController,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Correo electrónico',
                prefixIcon: Icon(Icons.mail_outline),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFF991B1B),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSending ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: _isSending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Enviar enlace'),
        ),
      ],
    );
  }
}

// Pantalla que reemplaza a WelcomePage cuando la URL trae el access_token de
// una invitación de personal o de un correo de recuperar contraseña (ver
// _extractInviteAccessToken en main() y POST /staff/accept-invite en
// server.mjs, que sirve para ambos).
class CreatePasswordPage extends StatefulWidget {
  const CreatePasswordPage({
    super.key,
    required this.accessToken,
    this.isRecovery = false,
  });

  final String accessToken;
  final bool isRecovery;

  @override
  State<CreatePasswordPage> createState() => _CreatePasswordPageState();
}

class _CreatePasswordPageState extends State<CreatePasswordPage> {
  static const _minPasswordLength = 8;

  final passwordController = TextEditingController();
  final confirmController = TextEditingController();

  bool get canSubmit =>
      passwordController.text.length >= _minPasswordLength &&
      confirmController.text.isNotEmpty &&
      !_isLoading;

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    passwordController.addListener(_refresh);
    confirmController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!canSubmit) return;

    if (passwordController.text != confirmController.text) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ApiService.acceptInvite(
        accessToken: widget.accessToken,
        password: passwordController.text,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => LoginPage(
            successMessage: widget.isRecovery
                ? 'Tu nueva contraseña quedó guardada. Ya puedes iniciar sesión.'
                : 'Tu contraseña quedó creada. Ya puedes iniciar sesión.',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible crear tu contraseña. Intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: NexaColors.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: NexaColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: NexaColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(
          color: NexaColors.primary,
          width: 2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.isRecovery ? 'Crea una nueva contraseña' : 'Crea tu contraseña';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: NexaColors.textPrimary,
          ),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Container(
              padding: const EdgeInsets.all(36),
              decoration: BoxDecoration(
                color: NexaColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: NexaColors.border),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 32,
                    offset: Offset(0, 14),
                    color: Color(0x140F172A),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: NexaColors.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.lock_person_outlined,
                        size: 36,
                        color: NexaColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: NexaColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.isRecovery
                        ? 'Elige una nueva contraseña para tu cuenta de Imagenda'
                        : 'Elige una contraseña para activar tu cuenta en Imagenda',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: NexaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    controller: passwordController,
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.next,
                    decoration: _inputDecoration(
                      label: 'Contraseña (mínimo $_minPasswordLength caracteres)',
                      icon: Icons.lock_outline,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: confirmController,
                    obscureText: _obscureConfirm,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: _inputDecoration(
                      label: 'Confirmar contraseña',
                      icon: Icons.lock_outline,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureConfirm
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() => _obscureConfirm = !_obscureConfirm);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF991B1B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: canSubmit ? _submit : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: NexaColors.primary,
                        disabledBackgroundColor: const Color(0xFFE2E8F0),
                        disabledForegroundColor: const Color(0xFF94A3B8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Crear contraseña',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    required this.showMenu,
  });

  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: NexaColors.surface,
        border: Border(
          bottom: BorderSide(color: NexaColors.border),
        ),
      ),
      child: Row(
        children: [
          if (showMenu)
            Builder(
              builder: (context) => IconButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(Icons.menu),
              ),
            ),
          const Spacer(),
          const Icon(
            Icons.notifications_none,
            color: NexaColors.textSecondary,
          ),
          const SizedBox(width: 20),
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: NexaColors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Text(
              'M',
              style: TextStyle(
                color: NexaColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manuel',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: NexaColors.textPrimary,
                ),
              ),
              Text(
                'Administrador',
                style: TextStyle(
                  fontSize: 12,
                  color: NexaColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PromptBox extends StatelessWidget {
  const PromptBox({
    super.key,
    required this.controller,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: NexaColors.border),
        boxShadow: const [
          BoxShadow(
            blurRadius: 28,
            offset: Offset(0, 12),
            color: Color(0x0F0F172A),
          ),
        ],
      ),
      child: Column(
        children: [
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Describe tu tarea o haz una pregunta...',
              border: InputBorder.none,
            ),
          ),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'La carga de archivos se activará pronto.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.attach_file),
                label: const Text('Adjuntar'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: onSend,
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Enviar'),
                style: FilledButton.styleFrom(
                  backgroundColor: NexaColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class QuickActionCard extends StatelessWidget {
  const QuickActionCard({
    super.key,
    required this.action,
    required this.onTap,
  });

  final QuickAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NexaColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: NexaColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: NexaColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  action.icon,
                  color: NexaColors.primary,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Text(
                  action.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: NexaColors.textPrimary,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: NexaColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuickAction {
  const QuickAction({
    required this.title,
    required this.prompt,
    required this.icon,
  });

  final String title;
  final String prompt;
  final IconData icon;
}

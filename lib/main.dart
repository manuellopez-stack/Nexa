import 'widgets/today_patients_section.dart';
import 'widgets/nexa_ai_section.dart';
import 'widgets/operational_status_section.dart';
import 'widgets/dashboard_kpi_section.dart';
import 'package:flutter/material.dart';

import 'core/nexa_colors.dart';
import 'screens/staff_management_page.dart';
import 'services/api_service.dart';

void main() {
  runApp(const NexaApp());
}

class NexaApp extends StatelessWidget {
  const NexaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: NexaColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: NexaColors.primary,
          brightness: Brightness.light,
        ),
      ),
      home: const WelcomePage(),
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
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: NexaColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(
                    Icons.auto_awesome,
                    size: 52,
                    color: NexaColors.primary,
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Nexa',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    color: NexaColors.textPrimary,
                    letterSpacing: -1.2,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'La IA que entiende\ncómo trabaja tu empresa',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
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
  const LoginPage({super.key});

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
  String? _error;

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

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
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
          'Acceso a Nexa',
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
                        Icons.auto_awesome,
                        size: 36,
                        color: NexaColors.primary,
                      ),
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
                  TextField(
                    controller: emailController,
                    decoration: _inputDecoration(
                      label: 'Correo electrónico',
                      icon: Icons.mail_outline,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: _inputDecoration(
                      label: 'Contraseña',
                      icon: Icons.lock_outline,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: AppBar(
        title: const Text(
          'Centro de Control',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: NexaColors.textPrimary,
          ),
        ),
        backgroundColor: NexaColors.surface,
        actions: [
          if (ApiService.role == 'administrador')
            IconButton(
              tooltip: 'Gestión de equipo',
              icon: const Icon(
                Icons.groups_outlined,
                color: NexaColors.textSecondary,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const StaffManagementPage(),
                  ),
                );
              },
            ),
          if (ApiService.currentUser?['email'] != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  ApiService.currentUser!['email'].toString(),
                  style: const TextStyle(
                    color: NexaColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout, color: NexaColors.textSecondary),
            onPressed: () {
              ApiService.logout();
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (route) => false,
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
  padding: const EdgeInsets.all(28),
  child: Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1250),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Resumen ejecutivo de la operación de hoy',
            style: TextStyle(
              fontSize: 15,
              color: NexaColors.textSecondary,
            ),
          ),
          SizedBox(height: 24),
          DashboardKpiSection(),
          SizedBox(height: 28),
OperationalStatusSection(),
SizedBox(height: 28),
NexaAiSection(),
SizedBox(height: 28),
TodayPatientsSection(),
        ],
      ),
    ),
  ),
),
    );
  }
}class NexaSidebar extends StatelessWidget {
  const NexaSidebar({
    super.key,
    required this.onLogout,
  });

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NexaColors.sidebar,
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NexaLogo(),
          const SizedBox(height: 34),
          const SidebarItem(
            icon: Icons.home_outlined,
            title: 'Inicio',
            selected: true,
          ),
          const SidebarItem(
            icon: Icons.chat_bubble_outline,
            title: 'Conversaciones',
          ),
          const SidebarItem(
            icon: Icons.folder_outlined,
            title: 'Documentos',
          ),
          const SidebarItem(
            icon: Icons.bolt_outlined,
            title: 'Automatizaciones',
          ),
          const SidebarItem(
            icon: Icons.settings_outlined,
            title: 'Configuración',
          ),
          const Spacer(),
          const Divider(color: NexaColors.border),
          ListTile(
            onTap: onLogout,
            leading: const Icon(
              Icons.logout,
              color: NexaColors.textSecondary,
            ),
            title: const Text(
              'Cerrar sesión',
              style: TextStyle(
                color: NexaColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NexaLogo extends StatelessWidget {
  const NexaLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: NexaColors.primary,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(
            Icons.auto_awesome,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'Nexa',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w800,
            color: NexaColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class SidebarItem extends StatelessWidget {
  const SidebarItem({
    super.key,
    required this.icon,
    required this.title,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected
            ? NexaColors.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: selected
              ? NexaColors.primary
              : NexaColors.textSecondary,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: selected
                ? NexaColors.primary
                : NexaColors.textPrimary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

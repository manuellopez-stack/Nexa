import 'package:flutter/material.dart';

class TodayPatientsSection extends StatelessWidget {
  const TodayPatientsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final patients = [
      {
        'time': '08:30',
        'name': 'María Soto',
        'exam': 'Ecografía abdominal',
        'room': 'Sala 1',
        'status': 'En atención',
      },
      {
        'time': '08:45',
        'name': 'Juan Pérez',
        'exam': 'Mamografía',
        'room': 'Sala 2',
        'status': 'Esperando',
      },
      {
        'time': '09:00',
        'name': 'Ana Rojas',
        'exam': 'Rayos X de tórax',
        'room': 'Sala 3',
        'status': 'Programado',
      },
      {
        'time': '09:15',
        'name': 'Carlos Díaz',
        'exam': 'Ecografía Doppler',
        'room': 'Sala 1',
        'status': 'Programado',
      },
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFE2E8F0),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D0F172A),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.people_alt_outlined,
                color: Color(0xFF2563EB),
              ),
              SizedBox(width: 10),
              Text(
                'Pacientes del día',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Próximas atenciones programadas',
            style: TextStyle(
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 22),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(
                Color(0xFFF8FAFC),
              ),
              columns: const [
                DataColumn(label: Text('Hora')),
                DataColumn(label: Text('Paciente')),
                DataColumn(label: Text('Examen')),
                DataColumn(label: Text('Sala')),
                DataColumn(label: Text('Estado')),
              ],
              rows: patients.map((patient) {
                return DataRow(
                  cells: [
                    DataCell(Text(patient['time']!)),
                    DataCell(
                      Text(
                        patient['name']!,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    DataCell(Text(patient['exam']!)),
                    DataCell(Text(patient['room']!)),
                    DataCell(
                      _StatusBadge(
                        status: patient['status']!,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.status,
  });

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (status) {
      case 'En atención':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        icon = Icons.check_circle_outline;
        break;
      case 'Esperando':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        icon = Icons.schedule;
        break;
      default:
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        icon = Icons.event_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: textColor,
          ),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
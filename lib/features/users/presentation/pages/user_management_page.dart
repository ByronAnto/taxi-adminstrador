import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/models/user_model.dart';
import '../bloc/user_management_bloc.dart';

/// Página de administración de usuarios
class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});

  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const _roles = ['conductor', 'operadora', 'admin'];
  static const _roleLabels = ['Conductores', 'Operadoras', 'Admins'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    context.read<UserManagementBloc>().add(UsersLoadRequested());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<UserModel> _filterUsers(List<UserModel> all, String role) {
    var filtered = all.where((u) => u.role == role).toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((u) {
        final fullName = '${u.name} ${u.lastname}'.toLowerCase();
        return fullName.contains(q) ||
            u.email.toLowerCase().contains(q) ||
            u.cedula.contains(q);
      }).toList();
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestión de Usuarios'),
        bottom: TabBar(
          controller: _tabController,
          tabs: _roleLabels.map((l) => Tab(text: l)).toList(),
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Buscar por nombre, email o cédula...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),

          // Content
          Expanded(
            child: BlocConsumer<UserManagementBloc, UserManagementState>(
              listener: (context, state) {
                if (state is UserManagementActionSuccess) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.message),
                      backgroundColor: AppTheme.successColor,
                    ),
                  );
                  context
                      .read<UserManagementBloc>()
                      .add(UsersLoadRequested());
                }
                if (state is UserManagementError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.message),
                      backgroundColor: AppTheme.errorColor,
                    ),
                  );
                }
              },
              builder: (context, state) {
                if (state is UserManagementLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                final allUsers = state is UserManagementLoaded
                    ? state.users
                    : <UserModel>[];

                return TabBarView(
                  controller: _tabController,
                  children: List.generate(3, (i) {
                    final users = _filterUsers(allUsers, _roles[i]);
                    return _buildUserList(users);
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserList(List<UserModel> users) {
    if (users.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 56, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isEmpty
                  ? 'No hay usuarios registrados'
                  : 'Sin resultados para "$_searchQuery"',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: users.length,
      itemBuilder: (ctx, i) => _buildUserCard(users[i]),
    );
  }

  Widget _buildUserCard(UserModel user) {
    final isActive = user.isActive;
    final initials =
        '${user.name.isNotEmpty ? user.name[0] : ''}${user.lastname.isNotEmpty ? user.lastname[0] : ''}'
            .toUpperCase();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: isActive
              ? AppTheme.primaryColor.withValues(alpha: 0.15)
              : Colors.grey[200],
          child: Text(
            initials,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isActive ? AppTheme.primaryColor : Colors.grey,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${user.name} ${user.lastname}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isActive ? null : Colors.grey,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isActive
                    ? AppTheme.successColor.withValues(alpha: 0.15)
                    : Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isActive ? 'Activo' : 'Inactivo',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isActive ? AppTheme.successColor : Colors.red,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          user.email,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                _infoRow(Icons.badge, 'Cédula', user.cedula),
                _infoRow(Icons.phone, 'Teléfono', user.phone),
                _infoRow(Icons.security, 'Rol', user.role),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          context.read<UserManagementBloc>().add(
                                UserToggleActiveRequested(
                                    user.uid, !user.isActive),
                              );
                        },
                        icon: Icon(
                          isActive ? Icons.block : Icons.check_circle,
                          size: 18,
                        ),
                        label: Text(isActive ? 'Desactivar' : 'Activar'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isActive ? Colors.red : AppTheme.successColor,
                          side: BorderSide(
                            color: isActive
                                ? Colors.red.withValues(alpha: 0.5)
                                : AppTheme.successColor.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

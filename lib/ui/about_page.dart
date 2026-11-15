import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'section_label.dart';

/// 关于页（P3-6）：版本/构建号、开源许可（一行式）、GitHub/Issue 链接、
/// 隐私声明（本地优先、无遥测、凭据仅本地安全存储）。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _repoUrl = 'https://github.com/SongRenShuo/zremote';
  static const _issuesUrl = 'https://github.com/SongRenShuo/zremote/issues';

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.zt.textLo),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Text(
          l10n.aboutTitle,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: context.zt.textHi,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final info = snapshot.data;
                return _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Image.asset('assets/brand/mark.png',
                              width: 28, height: 28),
                          const SizedBox(width: 10),
                          Text(
                            'ZRemote',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: context.zt.textHi,
                            ),
                          ),
                          const Spacer(),
                          if (info != null)
                            Text(
                              l10n.aboutVersionValue(
                                info.version,
                                info.buildNumber,
                              ),
                              style: zrMono(
                                fontSize: 11.5,
                                weight: FontWeight.w500,
                                color: context.zt.textLo,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            SectionLabel(l10n.aboutLinks),
            _LinkTile(
              key: const Key('about-github-link'),
              icon: Icons.code_rounded,
              label: l10n.aboutGitHub,
              sub: 'github.com/SongRenShuo/zremote',
              onTap: () => _open(_repoUrl),
            ),
            _LinkTile(
              key: const Key('about-issues-link'),
              icon: Icons.bug_report_outlined,
              label: l10n.aboutIssues,
              sub: 'github.com/SongRenShuo/zremote/issues',
              onTap: () => _open(_issuesUrl),
            ),
            const SizedBox(height: 12),
            SectionLabel(l10n.aboutPrivacy),
            _Card(
              child: Text(
                l10n.aboutPrivacyBody,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: context.zt.textLo,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SectionLabel(l10n.aboutLicenses),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.aboutLicenseJetbrains,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: context.zt.textLo,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.aboutLicenseDeps,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.6,
                      color: context.zt.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.zt.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zt.hairline),
      ),
      child: child,
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    super.key,
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.zt.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zt.hairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: context.zt.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      sub,
                      style:
                          TextStyle(fontSize: 11.5, color: context.zt.textLo),
                    ),
                  ],
                ),
              ),
              Icon(Icons.open_in_new_outlined,
                  size: 15, color: context.zt.textLo),
            ],
          ),
        ),
      ),
    );
  }
}

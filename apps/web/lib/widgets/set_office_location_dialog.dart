import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../app/services.dart';
import '../platform/bridge.dart';
import '../platform/geocoding.dart';
import 'async_view.dart';

/// Interactive modal sheet to view and configure real office GPS location and geofence radius.
Future<Map<String, dynamic>?> showSetOfficeLocationSheet(
  BuildContext context, {
  required Map<String, dynamic> location,
  VoidCallback? onLocationUpdated,
}) async {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _SetOfficeLocationSheet(
      location: location,
      onLocationUpdated: onLocationUpdated,
    ),
  );
}

class _SetOfficeLocationSheet extends StatefulWidget {
  const _SetOfficeLocationSheet({
    required this.location,
    this.onLocationUpdated,
  });

  final Map<String, dynamic> location;
  final VoidCallback? onLocationUpdated;

  @override
  State<_SetOfficeLocationSheet> createState() => _SetOfficeLocationSheetState();
}

class _SetOfficeLocationSheetState extends State<_SetOfficeLocationSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _latCtrl;
  late final TextEditingController _lngCtrl;
  late final TextEditingController _radiusCtrl;

  bool _isLocating = false;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final loc = widget.location;
    _nameCtrl = TextEditingController(text: (loc['name'] as String?) ?? 'Bulletproof Brands HQ');
    _addressCtrl = TextEditingController(text: (loc['address'] as String?) ?? 'SG Highway, Bodakdev, Ahmedabad');
    final lat = (loc['latitude'] as num?)?.toDouble() ?? 23.0225;
    final lng = (loc['longitude'] as num?)?.toDouble() ?? 72.5714;
    final rad = (loc['radiusMeters'] as num?)?.toDouble() ?? 150.0;
    _latCtrl = TextEditingController(text: lat.toStringAsFixed(6));
    _lngCtrl = TextEditingController(text: lng.toStringAsFixed(6));
    _radiusCtrl = TextEditingController(text: rad.round().toString());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _radiusCtrl.dispose();
    super.dispose();
  }

  Future<void> _useCurrentGpsLocation() async {
    setState(() {
      _isLocating = true;
      _errorMessage = null;
    });

    try {
      final fix = await bridge.currentPosition();
      final lat = fix.latitude;
      final lng = fix.longitude;

      _latCtrl.text = lat.toStringAsFixed(6);
      _lngCtrl.text = lng.toStringAsFixed(6);

      // Attempt reverse geocoding to resolve street address
      final address = await Geocoding.reverseGeocode(
        lat,
        lng,
        fallbackLocationName: _nameCtrl.text.isNotEmpty ? _nameCtrl.text : 'My Workplace',
      );

      if (mounted) {
        if (address.isNotEmpty) {
          _addressCtrl.text = address;
        }
        NToast.of(context).show('Office coordinates set to your current GPS position!');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not access device GPS. Please ensure location permission is allowed.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLocating = false);
      }
    }
  }

  void _applyPreset(String name, String address, double lat, double lng, int radius) {
    setState(() {
      _nameCtrl.text = name;
      _addressCtrl.text = address;
      _latCtrl.text = lat.toStringAsFixed(6);
      _lngCtrl.text = lng.toStringAsFixed(6);
      _radiusCtrl.text = radius.toString();
    });
  }

  Future<void> _saveLocation() async {
    final lat = double.tryParse(_latCtrl.text.trim());
    final lng = double.tryParse(_lngCtrl.text.trim());
    final radius = int.tryParse(_radiusCtrl.text.trim());
    final name = _nameCtrl.text.trim();
    final address = _addressCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please enter an office name.');
      return;
    }
    if (lat == null || lat < -90 || lat > 90) {
      setState(() => _errorMessage = 'Enter a valid latitude between -90 and 90.');
      return;
    }
    if (lng == null || lng < -180 || lng > 180) {
      setState(() => _errorMessage = 'Enter a valid longitude between -180 and 180.');
      return;
    }
    if (radius == null || radius < 10 || radius > 5000) {
      setState(() => _errorMessage = 'Enter an allowed radius between 10m and 5000m.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    final body = {
      'name': name,
      'address': address,
      'latitude': lat,
      'longitude': lng,
      'radiusMeters': radius,
      'active': true,
    };

    try {
      final locId = widget.location['id'] ?? widget.location['_id'];
      Map<String, dynamic> result;
      if (locId != null && '$locId'.isNotEmpty) {
        result = jsonMap(await context.api.patch('/locations/$locId', body: body));
      } else {
        result = jsonMap(await context.api.post('/locations', body: body));
      }

      if (mounted) {
        NToast.of(context).show('Office real location updated to $name!');
        widget.onLocationUpdated?.call();
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to save location. Please try again.';
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + bottomInset),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.90,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: t.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.business_rounded, color: t.accent, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Set Office Real Location',
                        style: t.text.title(size: 16).copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Configure workplace GPS coordinates & geofence perimeter',
                        style: t.text.caption(color: t.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 1-Click GPS Button
            InkWell(
              onTap: _isLocating ? null : _useCurrentGpsLocation,
              borderRadius: BorderRadius.circular(t.radiusCard),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      t.accent.withValues(alpha: t.isDark ? 0.35 : 0.15),
                      t.green.withValues(alpha: t.isDark ? 0.25 : 0.12),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(t.radiusCard),
                  border: Border.all(color: t.accent.withValues(alpha: 0.6), width: 1.5),
                ),
                child: Row(
                  children: [
                    if (_isLocating)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: t.accent),
                      )
                    else
                      Icon(Icons.my_location_rounded, color: t.accent, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isLocating ? 'Detecting high-precision GPS...' : '📍 Use My Current Location as Office',
                            style: t.text.body(weight: FontWeight.w700).copyWith(color: t.accent),
                          ),
                          Text(
                            'Captures device coordinates & automatically looks up street address',
                            style: t.text.caption(color: t.muted).copyWith(fontSize: 10.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Presets
            Text(
              'Quick Presets:',
              style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.apartment_rounded, size: 14),
                  label: const Text('Bulletproof Brands HQ (Ahmedabad)'),
                  labelStyle: const TextStyle(fontSize: 11),
                  onPressed: () => _applyPreset(
                    'Bulletproof Brands HQ',
                    'SG Highway, Bodakdev, Ahmedabad',
                    23.0225,
                    72.5714,
                    150,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.location_city_rounded, size: 14),
                  label: const Text('Mumbai BKC Studio'),
                  labelStyle: const TextStyle(fontSize: 11),
                  onPressed: () => _applyPreset(
                    'Mumbai BKC Studio',
                    'Bandra Kurla Complex, Mumbai',
                    19.0657,
                    72.8687,
                    150,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.hub_rounded, size: 14),
                  label: const Text('Bengaluru Tech Park'),
                  labelStyle: const TextStyle(fontSize: 11),
                  onPressed: () => _applyPreset(
                    'Bengaluru Tech Park',
                    'Outer Ring Road, Bellandur, Bengaluru',
                    12.9279,
                    77.6771,
                    150,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.red.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, size: 16, color: t.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: t.text.caption(color: t.red),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Input Fields
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Workplace / Office Name',
                prefixIcon: Icon(Icons.badge_outlined, size: 18),
                hintText: 'e.g. Bulletproof Brands HQ',
              ),
            ),
            const SizedBox(height: 10),

            TextField(
              controller: _addressCtrl,
              decoration: const InputDecoration(
                labelText: 'Street Address',
                prefixIcon: Icon(Icons.place_outlined, size: 18),
                hintText: 'e.g. SG Highway, Bodakdev, Ahmedabad',
              ),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Latitude',
                      prefixIcon: Icon(Icons.navigation_rounded, size: 16),
                      hintText: '23.022500',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _lngCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'Longitude',
                      prefixIcon: Icon(Icons.explore_outlined, size: 16),
                      hintText: '72.571400',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _radiusCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Allowed Radius (metres)',
                      prefixIcon: Icon(Icons.radar_rounded, size: 18),
                      suffixText: 'm',
                      hintText: '100',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final r in [50, 100, 150, 250])
                      ChoiceChip(
                        label: Text('${r}m', style: const TextStyle(fontSize: 10.5)),
                        selected: _radiusCtrl.text == '$r',
                        onSelected: (_) => setState(() => _radiusCtrl.text = '$r'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Save Button
            NButton(
              label: _isSaving ? 'Saving Office Location...' : 'Save Office Location',
              icon: Icons.check_circle_rounded,
              busy: _isSaving,
              onPressed: _isSaving ? null : _saveLocation,
            ),
          ],
        ),
      ),
    );
  }
}

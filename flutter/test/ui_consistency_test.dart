import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BoxPanel uses a full-width card radius and inherited surface', (
    tester,
  ) async {
    late BuildContext panelContext;
    late BuildContext childContext;
    await tester.pumpWidget(
      TestApp(
        child: SurfaceScope(
          level: SurfaceLevel.page,
          child: BoxPanel(
            child: Builder(
              builder: (context) {
                childContext = context;
                return const Text('Panel');
              },
            ),
          ),
        ),
      ),
    );
    panelContext = tester.element(find.byType(BoxPanel));
    final surface = tester.widget<Surface>(find.byType(Surface));
    expect(surface.color, SurfaceLevel.card.colorOf(panelContext.colorScheme));
    expect(surface.shape, AppShape.all(AppCorner.xl));
    expect(SurfaceScope.of(childContext), SurfaceLevel.card);
    expect(tester.takeException(), isNull);
  });

  testWidgets('boxPagePadding preserves the page contract', (tester) async {
    late EdgeInsets padding;
    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (context) {
            padding = boxPagePadding(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(padding.left, 16);
    expect(padding.right, 16);
    expect(padding.top, greaterThan(0));
    expect(padding.bottom, greaterThanOrEqualTo(24));
  });

  testWidgets('showAppDialog uses the Prism route and preserves its result', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showAppDialog<String>(
                context,
                child: Builder(
                  builder: (dialogContext) => AlertDialog(
                    title: 'Choose',
                    child: Text('Body'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, 'saved'),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(SurfaceScope.of(tester.element(find.text('Body'))),
        SurfaceLevel.floatingOf(tester.element(find.text('Body')).colorScheme));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showOptionSheet preserves selection and typed cancellation', (
    tester,
  ) async {
    int? result;
    var opened = false;
    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              opened = true;
              result = await showOptionSheet<int>(
                context: context,
                title: 'Mode',
                options: const [(1, 'One'), (2, 'Two')],
                selected: 1,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(result, 2);
    expect(tester.takeException(), isNull);
  });
}

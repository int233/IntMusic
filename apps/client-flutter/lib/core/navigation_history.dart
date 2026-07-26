/// Framework-independent navigation history used by the desktop-style
/// back/forward controls.
///
/// Feature routes remain owned by the application layer; this class only owns
/// deterministic history behavior and can therefore be tested without widgets.
class NavigationHistory<T> {
  NavigationHistory(this._current, {this.maximumDepth = 100})
    : assert(maximumDepth > 0);

  final int maximumDepth;
  final List<T> _back = <T>[];
  final List<T> _forward = <T>[];
  T _current;

  T get current => _current;
  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  int get backDepth => _back.length;
  int get forwardDepth => _forward.length;

  bool navigateTo(T destination) {
    if (_current == destination) return false;
    _back.add(_current);
    if (_back.length > maximumDepth) {
      _back.removeAt(0);
    }
    _forward.clear();
    _current = destination;
    return true;
  }

  T? goBack() {
    if (_back.isEmpty) return null;
    _forward.add(_current);
    _current = _back.removeLast();
    return _current;
  }

  T? goForward() {
    if (_forward.isEmpty) return null;
    _back.add(_current);
    _current = _forward.removeLast();
    return _current;
  }

  void replace(T destination, {bool clearForward = false}) {
    _current = destination;
    if (clearForward) {
      _forward.clear();
    }
  }

  void clear({required T destination}) {
    _back.clear();
    _forward.clear();
    _current = destination;
  }
}

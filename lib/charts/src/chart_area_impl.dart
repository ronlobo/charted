//
// Copyright 2014 Google Inc. All rights reserved.
//
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file or at
// https://developers.google.com/open-source/licenses/bsd
//

part of charted.charts;

/// Displays either one or two dimension axes and zero or more measure axis.
/// The number of measure axes displayed is zero in charts like bubble chart
/// which contain two dimension axes.
class CartesianChartArea implements ChartArea {
  /// Default identifiers used by the measure axes
  static const MEASURE_AXIS_IDS = const['_default'];

  /// Orientations used by measure axes. First, when "x" axis is the primary
  /// and the only dimension. Second, when "y" axis is the primary and the only
  /// dimension.
  static const MEASURE_AXIS_ORIENTATIONS = const[
    const[ORIENTATION_LEFT, ORIENTATION_RIGHT],
    const[ORIENTATION_BOTTOM, ORIENTATION_TOP]
  ];

  /// Orientations used by the dimension axes. First, when "x" is the
  /// primary dimension and the last one for cases where "y" axis is primary
  /// dimension.
  static const DIMENSION_AXIS_ORIENTATIONS = const[
    const[ORIENTATION_BOTTOM, ORIENTATION_LEFT],
    const[ORIENTATION_LEFT, ORIENTATION_BOTTOM]
  ];

  /// Mapping of measure axis Id to it's axis.
  final _measureAxes = new LinkedHashMap<String, _ChartAxis>();

  /// Mapping of dimension column index to it's axis.
  final _dimensionAxes = new LinkedHashMap<int, _ChartAxis>();

  /// Disposer for all change stream subscriptions related to data.
  final _dataEventsDisposer = new SubscriptionsDisposer();

  /// Disposer for all change stream subscriptions related to config.
  final _configEventsDisposer = new SubscriptionsDisposer();

  @override
  final Element host;

  @override
  final bool useTwoDimensionAxes;

  /// Indicates whether any renderers need bands on primary dimension
  final List<int> dimensionsUsingBands = [];

  @override
  _ChartAreaLayout layout = new _ChartAreaLayout();

  @override
  Selection upperBehaviorPane;

  @override
  Selection lowerBehaviorPane;

  @override
  ChartTheme theme;

  ChartData _data;
  ChartConfig _config;
  ObservableList<int> selectedMeasures = new ObservableList();
  ObservableList<int> hoveredMeasures = new ObservableList();
  int _dimensionAxesCount;
  bool _autoUpdate = false;

  SelectionScope _scope;
  Selection _svg;
  Selection visualization;

  Iterable<ChartSeries> _series;

  bool _pendingLegendUpdate = false;
  List<ChartBehavior> _behaviors = new List<ChartBehavior>();
  Map<ChartSeries, _ChartSeriesInfo> _seriesInfoCache = new Map();

  StreamController<ChartEvent> _valueMouseOverController;
  StreamController<ChartEvent> _valueMouseOutController;
  StreamController<ChartEvent> _valueMouseClickController;

  CartesianChartArea(
      this.host,
      ChartData data,
      ChartConfig config,
      bool autoUpdate,
      this.useTwoDimensionAxes) : _autoUpdate = autoUpdate {
    assert(host != null);
    assert(isNotInline(host));

    this.data = data;
    this.config = config;
    theme = ChartTheme.current;

    Transition.defaultEasingType = theme.transitionEasingType;
    Transition.defaultEasingMode = theme.transitionEasingMode;
    Transition.defaultDuration = theme.transitionDuration;
  }

  void dispose() {
    _configEventsDisposer.dispose();
    _dataEventsDisposer.dispose();
    _config.legend.dispose();
  }

  static bool isNotInline(Element e) =>
      e != null && e.getComputedStyle().display != 'inline';

  /// Set new data for this chart. If [value] is [Observable], subscribes to
  /// changes and updates the chart when data changes.
  @override
  set data(ChartData value) {
    _data = value;
    _dataEventsDisposer.dispose();

    if (autoUpdate && _data != null && _data is Observable) {
      _dataEventsDisposer.add((_data as Observable).changes.listen((_) {
        draw();
      }));
    }
  }

  @override
  ChartData get data => _data;

  /// Set new config for this chart. If [value] is [Observable], subscribes to
  /// changes and updates the chart when series or dimensions change.
  @override
  set config(ChartConfig value) {
    _config = value;
    _configEventsDisposer.dispose();
    _pendingLegendUpdate = true;

    if (_config != null && _config is Observable) {
      _configEventsDisposer.add((_config as Observable).changes.listen((_) {
        _pendingLegendUpdate = true;
        draw();
      }));
    }
  }

  @override
  ChartConfig get config => _config;

  @override
  set autoUpdate(bool value) {
    if (_autoUpdate != value) {
      _autoUpdate = value;
      this.data = _data;
      this.config = _config;
    }
  }

  @override
  bool get autoUpdate => _autoUpdate;

  /// Gets measure axis from cache - creates a new instance of _ChartAxis
  /// if one was not already created for the given [axisId].
  _ChartAxis _getMeasureAxis(String axisId) {
    _measureAxes.putIfAbsent(axisId, () {
      var axisConf = config.getMeasureAxis(axisId),
          axis = axisConf != null ?
              new _ChartAxis.withAxisConfig(this, axisConf) :
                  new _ChartAxis(this);
      return axis;
    });
    return _measureAxes[axisId];
  }

  /// Gets a dimension axis from cache - creates a new instance of _ChartAxis
  /// if one was not already created for the given dimension [column].
  _ChartAxis _getDimensionAxis(int column) {
    _dimensionAxes.putIfAbsent(column, () {
      var axisConf = config.getDimensionAxis(column),
          axis = axisConf != null ?
              new _ChartAxis.withAxisConfig(this, axisConf) :
                  new _ChartAxis(this);
      return axis;
    });
    return _dimensionAxes[column];
  }

  /// All columns rendered by a series must be of the same type.
  bool _isSeriesValid(ChartSeries s) {
    var first = data.columns.elementAt(s.measures.first).type;
    return s.measures.every((i) =>
        (i < data.columns.length) && data.columns.elementAt(i).type == first);
  }

  @override
  Iterable<Scale> get dimensionScales =>
      config.dimensions.map((int column) => _getDimensionAxis(column).scale);

  @override
  Iterable<Scale> measureScales(ChartSeries series) {
    var axisIds = isNullOrEmpty(series.measureAxisIds)
        ? MEASURE_AXIS_IDS
        : series.measureAxisIds;
    return axisIds.map((String id) => _getMeasureAxis(id).scale);
  }

  /// Computes the size of chart and if changed from the previous time
  /// size was computed, sets attributes on svg element
  Rect _computeChartSize() {
    int width = host.clientWidth,
        height = host.clientHeight;

    if (config.minimumSize != null) {
      width = max([width, config.minimumSize.width]);
      height = max([height, config.minimumSize.height]);
    }

    Rect current = new Rect(0, 0, width, height);
    if (layout.chartArea == null || layout.chartArea != current) {
      _svg.attr('width', width.toString());
      _svg.attr('height', height.toString());
      layout.chartArea = current;
    }
    return layout.chartArea;
  }

  @override
  draw({bool preRender:false, Future schedulePostRender}) {
    assert(data != null && config != null);
    assert(config.series != null && config.series.isNotEmpty);

    // One time initialization.
    // Each [ChartArea] has it's own [SelectionScope]
    if (_scope == null) {
      _scope = new SelectionScope.element(host);
      _svg = _scope.append('svg:svg')..classed('charted-chart');

      lowerBehaviorPane = _svg.append('g')..classed('lower-render-pane');
      visualization = _svg.append('g')..classed('chart-wrapper');
      upperBehaviorPane = _svg.append('g')..classed('upper-render-pane');

      if (_behaviors.isNotEmpty) {
        _behaviors.forEach(
            (b) => b.init(this, upperBehaviorPane, lowerBehaviorPane));
      }
    }

    // Compute chart sizes and filter out unsupported series
    var size = _computeChartSize(),
        series = config.series.where((s) =>
            _isSeriesValid(s) && s.renderer.prepare(this, s)),
        selection = visualization.selectAll('.series-group').
            data(series, (x) => x.hashCode),
        axesDomainCompleter = new Completer();

    // Wait till the axes are rendered before rendering series.
    // In an SVG, z-index is based on the order of nodes in the DOM.
    axesDomainCompleter.future.then((_) {
      selection.enter.append('svg:g')..classed('series-group');
      String transform =
          'translate(${layout.renderArea.x},${layout.renderArea.y})';

      selection.each((ChartSeries s, _, Element group) {
        _ChartSeriesInfo info = _seriesInfoCache[s];
        if (info == null) {
          info = _seriesInfoCache[s] = new _ChartSeriesInfo(this, s);
        }
        info.check();
        group.attributes['transform'] = transform;
        s.renderer.draw(group,
            preRender:preRender, schedulePostRender:schedulePostRender);
      });

      // A series that was rendered earlier isn't there anymore, remove it
      selection.exit
        ..each((ChartSeries s, _, __) {
          var info = _seriesInfoCache.remove(s);
          if (info != null) {
            info.dispose();
          }
        })
        ..remove();
    });

    // Save the list of valid series and initialize axes.
    _series = series;
    _initAxes();

    // Render the chart, now that the axes layer is already in DOM.
    axesDomainCompleter.complete();

    // Updates the legend if required.
    _updateLegend();
  }

  /// Initialize the axes - required even if the axes are not being displayed.
  _initAxes() {
    Map measureAxisUsers = <String,Iterable<ChartSeries>>{};

    // Create necessary measures axes.
    // If measure axes were not configured on the series, default is used.
    _series.forEach((ChartSeries s) {
      var measureAxisIds = isNullOrEmpty(s.measureAxisIds)
          ? MEASURE_AXIS_IDS
          : s.measureAxisIds;
      measureAxisIds.forEach((axisId) {
        var axis = _getMeasureAxis(axisId),  // Creates axis if required
            users = measureAxisUsers[axisId];
        if (users == null) {
          measureAxisUsers[axisId] = [s];
        } else {
          users.add(s);
        }
      });
    });

    // Now that we know a list of series using each measure axis, configure
    // the input domain of each axis.
    measureAxisUsers.forEach((id, listOfSeries) {
      var sampleCol = listOfSeries.first.measures.first,
          sampleColSpec = data.columns.elementAt(sampleCol),
          axis = _getMeasureAxis(id),
          domain;

      if (sampleColSpec.useOrdinalScale) {
        throw new UnsupportedError(
            'Ordinal measure axes are not currently supported.');
      } else {
        // Extent is available because [ChartRenderer.prepare] was already
        // called (when checking for valid series in [draw].
        Iterable extents = listOfSeries.map((s) => s.renderer.extent);
        var lowest = min(extents.map((e) => e.min)),
            highest = max(extents.map((e) => e.max));

        // Use default domain if lowest and highest are the same, right now
        // lowest is always 0, change to lowest when we make use of it.
        // TODO(prsd): Allow negative values and non-zero lower values.
        domain = (highest != 0) ? [0, highest] : [0, 1];
      }
      axis.initAxisDomain(sampleCol, false, domain);
    });

    // Configure dimension axes.
    int dimensionAxesCount = useTwoDimensionAxes ? 2 : 1;
    config.dimensions.take(dimensionAxesCount).forEach((int column) {
       var axis = _getDimensionAxis(column),
           sampleColumnSpec = data.columns.elementAt(column),
           values = data.rows.map((row) => row.elementAt(column)),
           domain;

       if (sampleColumnSpec.useOrdinalScale) {
         domain = values.map((e) => e.toString()).toList();
       } else {
         var extent = new Extent.items(values);
         domain = [extent.min, extent.max];
       }
       axis.initAxisDomain(column, true, domain);
    });

    // See if any dimensions need "band" on the axis.
    dimensionsUsingBands.clear();
    List<bool> usingBands = [false, false];
    _series.forEach((ChartSeries s) =>
        s.renderer.dimensionsUsingBand.forEach((x) {
      if (x <= 1 && !(usingBands[x])) {
        usingBands[x] = true;
        dimensionsUsingBands.add(config.dimensions.elementAt(x));
      }
    }));

    // List of measure and dimension axes that are displayed
    var measureAxesCount = dimensionAxesCount == 1 ? 2 : 0,
        displayedMeasureAxes = (config.displayedMeasureAxes == null ?
            _measureAxes.keys.take(measureAxesCount) :
                config.displayedMeasureAxes.take(measureAxesCount)).
                    toList(growable:false),
        displayedDimensionAxes =
            config.dimensions.take(dimensionAxesCount).toList(growable:false);

    // Compute size of the dimension axes
    if (config.renderDimensionAxes != false) {
      var dimensionAxisOrientations = config.leftAxisIsPrimary
          ? DIMENSION_AXIS_ORIENTATIONS.last
          : DIMENSION_AXIS_ORIENTATIONS.first;
      for (int i = 0, len = displayedDimensionAxes.length; i < len; ++i) {
        var axis = _dimensionAxes[displayedDimensionAxes[i]],
            orientation = dimensionAxisOrientations[i];
        axis.prepareToDraw(orientation, theme.dimensionAxisTheme);
        layout._axes[orientation] = axis.size;
      }
    }

    // Compute size of the measure axes
    if (displayedMeasureAxes.isNotEmpty) {
      var measureAxisOrientations = config.leftAxisIsPrimary
          ? MEASURE_AXIS_ORIENTATIONS.last
          : MEASURE_AXIS_ORIENTATIONS.first;
      displayedMeasureAxes.asMap().forEach((int index, String key) {
        var axis = _measureAxes[key],
            orientation = measureAxisOrientations[index];
        axis.prepareToDraw(orientation, theme.measureAxisTheme);
        layout._axes[orientation] = axis.size;
      });
    }

    // Consolidate all the information that we collected into final layout
    _computeLayout(
        displayedMeasureAxes.isEmpty && config.renderDimensionAxes == false);

    // Domains for all axes have been taken care of and _ChartAxis ensures
    // that the scale is initialized on visible axes. Initialize the scale on
    // all invisible measure scales.
    if (_measureAxes.length != displayedMeasureAxes.length) {
      _measureAxes.keys.forEach((String axisId) {
        if (displayedMeasureAxes.contains(axisId)) return;
        _getMeasureAxis(axisId).initAxisScale(
            [layout.renderArea.height, 0], theme.measureAxisTheme);
      });
    }

    // Draw the visible measure axes, if any.
    if (displayedMeasureAxes.isNotEmpty) {
      var axisGroups = visualization.
          selectAll('.measure-group').data(displayedMeasureAxes);
      // Update measure axis (add/remove/update)
      axisGroups.enter.append('svg:g');
      axisGroups.each((axisId, index, group) {
        _getMeasureAxis(axisId).draw(group);
        group.classes.clear();
        group.classes.addAll(['measure-group','measure-${index}']);
      });
      axisGroups.exit.remove();
    }

    // Draw the dimension axes, unless asked not to.
    if (config.renderDimensionAxes != false) {
      var dimAxisGroups = visualization.
          selectAll('.dimension-group').data(displayedDimensionAxes);
      // Update dimension axes (add/remove/update)
      dimAxisGroups.enter.append('svg:g');
      dimAxisGroups.each((column, index, group) {
        _getDimensionAxis(column).draw(group);
        group.classes.clear();
        group.classes.addAll(['dimension-group', 'dim-${index}']);
      });
      dimAxisGroups.exit.remove();
    } else {
      // Initialize scale on invisible axis
      var dimensionAxisOrientations = config.leftAxisIsPrimary ?
          DIMENSION_AXIS_ORIENTATIONS.last : DIMENSION_AXIS_ORIENTATIONS.first;
      for (int i = 0; i < dimensionAxesCount; ++i) {
        var column = config.dimensions.elementAt(i),
            axis = _dimensionAxes[column],
            orientation = dimensionAxisOrientations[i];
        axis.initAxisScale(orientation == ORIENTATION_LEFT ?
            [layout.renderArea.height, 0] : [0, layout.renderArea.width],
            theme.dimensionAxisTheme);
      };
    }
  }

  // Compute chart render area size and positions of all elements
  _computeLayout(bool notRenderingAxes) {
    if (notRenderingAxes) {
      layout.renderArea =
          new Rect(0, 0, layout.chartArea.height, layout.chartArea.width);
      return;
    }

    var top = layout.axes[ORIENTATION_TOP],
        left = layout.axes[ORIENTATION_LEFT],
        bottom = layout.axes[ORIENTATION_BOTTOM],
        right = layout.axes[ORIENTATION_RIGHT];

    var renderAreaHeight = layout.chartArea.height -
            (top.height + layout.axes[ORIENTATION_BOTTOM].height),
        renderAreaWidth = layout.chartArea.width -
            (left.width + layout.axes[ORIENTATION_RIGHT].width);

    layout.renderArea = new Rect(
        left.width, top.height, renderAreaWidth, renderAreaHeight);

    layout._axes
      ..[ORIENTATION_TOP] =
          new Rect(left.width, 0, renderAreaWidth, top.height)
      ..[ORIENTATION_RIGHT] =
          new Rect(left.width + renderAreaWidth, top.y,
              right.width, renderAreaHeight)
      ..[ORIENTATION_BOTTOM] =
          new Rect(left.width, top.height + renderAreaHeight,
              renderAreaWidth, bottom.height)
      ..[ORIENTATION_LEFT] =
          new Rect(
              left.width, top.height, left.width, renderAreaHeight);
  }

  // Updates the legend, if configuration changed since the last
  // time the legend was updated.
  _updateLegend() {
    if (!_pendingLegendUpdate) return;
    if (_config == null || _config.legend == null || _series.isEmpty) return;

    var legend = <ChartLegendItem>[];
    List seriesByColumn =
        new List.generate(data.columns.length, (_) => new List());

    _series.forEach((s) =>
        s.measures.forEach((m) => seriesByColumn[m].add(s)));

    seriesByColumn.asMap().forEach((int i, List s) {
      if (s.length == 0) return;
      legend.add(new ChartLegendItem(
          column:i, label:data.columns.elementAt(i).label, series:s,
          color:theme.getColorForKey(i)));
    });

    _config.legend.update(legend, this);
    _pendingLegendUpdate = false;
  }

  @override
  Stream<ChartEvent> get onMouseUp =>
      host.onMouseUp
          .map((MouseEvent e) => new _ChartEvent(e, this));

  @override
  Stream<ChartEvent> get onMouseDown =>
      host.onMouseDown
          .map((MouseEvent e) => new _ChartEvent(e, this));

  @override
  Stream<ChartEvent> get onMouseOver =>
      host.onMouseOver
          .map((MouseEvent e) => new _ChartEvent(e, this));

  @override
  Stream<ChartEvent> get onMouseOut =>
      host.onMouseOut
          .map((MouseEvent e) => new _ChartEvent(e, this));

  @override
  Stream<ChartEvent> get onMouseMove =>
      host.onMouseMove
          .map((MouseEvent e) => new _ChartEvent(e, this));

  @override
  Stream<ChartEvent> get onValueClick {
    if (_valueMouseClickController == null) {
      _valueMouseClickController = new StreamController.broadcast(sync: true);
    }
    return _valueMouseClickController.stream;
  }

  @override
  Stream<ChartEvent> get onValueMouseOver {
    if (_valueMouseOverController == null) {
      _valueMouseOverController = new StreamController.broadcast(sync: true);
    }
    return _valueMouseOverController.stream;
  }

  @override
  Stream<ChartEvent> get onValueMouseOut {
    if (_valueMouseOutController == null) {
      _valueMouseOutController = new StreamController.broadcast(sync: true);
    }
    return _valueMouseOutController.stream;
  }

  @override
  void addChartBehavior(ChartBehavior behavior) {
    if (behavior == null || _behaviors.contains(behavior)) return;
    _behaviors.add(behavior);
    if (upperBehaviorPane != null && lowerBehaviorPane != null) {
      behavior.init(this, upperBehaviorPane, lowerBehaviorPane);
    }
  }

  @override
  void removeChartBehavior(ChartBehavior behavior) {
    if (behavior == null || !_behaviors.contains(behavior)) return;
    if (upperBehaviorPane != null && lowerBehaviorPane != null) {
      behavior.dispose();
    }
    _behaviors.remove(behavior);
  }
}

class _ChartAreaLayout implements ChartAreaLayout {
  final _axes = <String, Rect>{
      ORIENTATION_LEFT: const Rect(),
      ORIENTATION_RIGHT: const Rect(),
      ORIENTATION_TOP: const Rect(),
      ORIENTATION_BOTTOM: const Rect()
    };

  UnmodifiableMapView<String, Rect> _axesView;

  @override
  get axes => _axesView;

  @override
  Rect renderArea;

  @override
  Rect chartArea;

  _ChartAreaLayout() {
    _axesView = new UnmodifiableMapView(_axes);
  }
}

class _ChartSeriesInfo {
  ChartRenderer _renderer;
  SubscriptionsDisposer _disposer = new SubscriptionsDisposer();

  _ChartSeries _series;
  CartesianChartArea _area;
  _ChartSeriesInfo(this._area, this._series);

  _event(StreamController controller, ChartEvent evt) {
    if (controller == null) return;
    controller.add(evt);
  }

  check() {
    if (_renderer != _series.renderer) dispose();
    _renderer = _series.renderer;
    try {
      _disposer.addAll([
          _renderer.onValueMouseClick.listen(
              (ChartEvent e) => _event(_area._valueMouseClickController, e)),
          _renderer.onValueMouseOver.listen(
              (ChartEvent e) => _event(_area._valueMouseOverController, e)),
          _renderer.onValueMouseOut.listen(
              (ChartEvent e) => _event(_area._valueMouseOutController, e))
      ]);
    } on UnimplementedError {};
  }

  dispose() => _disposer.dispose();
}

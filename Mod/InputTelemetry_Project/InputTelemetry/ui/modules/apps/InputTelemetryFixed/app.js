// Input Telemetry (fixed port) -- live throttle / brake / clutch / steering graph.
//
// Ported from ArmensG "Input Telemetry" v0.1 (last upstream update 2024).
// Behaviour kept: same three mirrors + rolling graph, same colours, same panel size.
// Fixed here:
//   1. the app asks for its data instead of assuming it arrives. Upstream subscribed to
//      nothing, so the UI bridge only delivered streams other apps had requested and
//      `streams.electrics` was undefined -> TypeError (reading 'clutch') every frame.
//      This port subscribes to its own channel, `inputTelemetryFixed`, published by
//      lua/vehicle/extensions/auto/inputTelemetryFixed.lua. It deliberately does not
//      share `electrics`: that channel is ref-counted across every app, so another app
//      removing its subscription too often would silently starve this one.
//   2. guards the payload and treats missing / NaN channels as 0, so a vehicle without
//      a clutch reading no longer produces "NaN%".
//   3. scoped DOM lookups (`root.querySelector`) instead of document-wide ids, and the
//      canvas drawing buffer is sized on mount as well as on `app:resized`.
angular.module('beamng.apps')
.directive('inputTelemetryFixed', [function () {
  var STREAM = 'inputTelemetryFixed'

  return {
    template: [
      '<div class="itf-root" style="height:100%; box-sizing:border-box; font-family:Consolas,Monaco,Lucida Console,Liberation Mono; background-color:rgba(50,50,50,0.9)">',
      '  <div class="itf-row" style="display:flex; height:100%; padding:10px; box-sizing:border-box">',
      '    <canvas class="itf-canvas" style="flex:1 1 auto; min-width:60px" width="300" height="130"></canvas>',
      '    <div class="itf-slot" style="width:5%; min-width:8px; margin-left:15px; background-color:rgba(50,50,50,0.9); transform:rotate(180deg)">',
      '      <div class="itf-bar itf-bar--clutch" style="height:0; width:100%; background-color:#00008B"></div>',
      '    </div>',
      '    <div class="itf-slot" style="width:5%; min-width:8px; margin-left:10px; background-color:rgba(50,50,50,0.9); transform:rotate(180deg)">',
      '      <div class="itf-bar itf-bar--brake" style="height:0; width:100%; background-color:#FF0000"></div>',
      '    </div>',
      '    <div class="itf-slot" style="width:5%; min-width:8px; margin-left:10px; background-color:rgba(50,50,50,0.9); transform:rotate(180deg)">',
      '      <div class="itf-bar itf-bar--gas" style="height:0; width:100%; background-color:#00FF00"></div>',
      '    </div>',
      '  </div>',
      '</div>'
    ].join(''),

    replace: true,
    restrict: 'EA',

    link: function (scope, element) {
      var root = element[0]
      var canvas = root.querySelector('canvas')
      var clutchBar = root.querySelector('.itf-bar--clutch')
      var brakeBar = root.querySelector('.itf-bar--brake')
      var gasBar = root.querySelector('.itf-bar--gas')

      var chart = new SmoothieChart({
        minValue: 0,
        maxValue: 100,
        millisPerPixel: 20,
        grid: {
          fillStyle: 'rgba(50, 50, 50, 0.9)',
          strokeStyle: 'rgba(20, 20, 20, 0.9)',
          verticalSections: 5,
          millisPerLine: 1000,
          sharpLines: true
        },
        labels: { disabled: true }
      })
      var gasGraph = new TimeSeries()
      var brakeGraph = new TimeSeries()
      var clutchGraph = new TimeSeries()
      var steeringGraph = new TimeSeries()

      chart.addTimeSeries(clutchGraph, { strokeStyle: '#00008B', lineWidth: 3 })
      chart.addTimeSeries(gasGraph, { strokeStyle: '#00FF00', lineWidth: 3 })
      chart.addTimeSeries(brakeGraph, { strokeStyle: '#FF0000', lineWidth: 3 })
      chart.addTimeSeries(steeringGraph, { strokeStyle: '#808080', lineWidth: 3 })
      chart.streamTo(canvas, 40)

      if (typeof StreamsManager !== 'undefined' && StreamsManager && StreamsManager.add) {
        StreamsManager.add([STREAM])
      }

      scope.$on('$destroy', function () {
        if (typeof StreamsManager !== 'undefined' && StreamsManager && StreamsManager.remove) {
          StreamsManager.remove([STREAM])
        }
        if (chart && typeof chart.stop === 'function') chart.stop()
      })

      function syncCanvasBuffer(fallbackWidth, fallbackHeight) {
        if (!canvas) return
        var w = Math.round(canvas.clientWidth || fallbackWidth || 300)
        var h = Math.round(canvas.clientHeight || fallbackHeight || 130)
        if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
          canvas.width = w
          canvas.height = h
        }
      }

      // the slot is laid out by the host; wait one frame so clientWidth/clientHeight exist
      var raf = window.requestAnimationFrame || function (fn) { return setTimeout(fn, 16) }
      raf(function () { syncCanvasBuffer() })

      scope.$on('app:resized', function (event, data) {
        if (!data) return
        syncCanvasBuffer(data.width - 130, data.height - 20)
      })

      function num(value) {
        return (typeof value === 'number' && isFinite(value)) ? value : 0
      }

      function percent(value) {
        return Math.max(0, Math.min(100, Math.round(num(value) * 100)))
      }

      function setBar(bar, value) {
        if (bar) bar.style.height = value + '%'
      }

      scope.$on('streamsUpdate', function (event, streams) {
        var inputs = streams && streams[STREAM]
        if (!inputs) return

        var clutchVal = percent(inputs.clutch)
        var brakeVal = percent(inputs.brake)
        var throttleVal = percent(inputs.throttle)
        var steeringVal = Math.max(0, Math.min(100, num(inputs.steeringInput) * 50 + 50))

        setBar(clutchBar, clutchVal)
        setBar(brakeBar, brakeVal)
        setBar(gasBar, throttleVal)

        var xPoint = new Date()
        gasGraph.append(xPoint, throttleVal)
        brakeGraph.append(xPoint, brakeVal)
        clutchGraph.append(xPoint, clutchVal)
        steeringGraph.append(xPoint, steeringVal)
      })
    }
  }
}])

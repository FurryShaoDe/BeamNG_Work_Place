angular.module("beamng.apps")
    .directive("tyreWearThermals", ["CanvasShortcuts", function (CanvasShortcuts) {
        return {
            template:
                '<div class="tyre-thermals-root">' +
                    '<style>' +
                        '.tyre-thermals-root{position:relative;width:100%;height:100%;overflow:visible;}' +
                        '.tyre-thermals-root canvas{display:block;width:100%;height:100%;}' +
                        '.tyre-thermals-root.fullscreen-debug-active>canvas{opacity:0!important;}' +
                        '.tyre-thermals-root.fullscreen-debug-active>.tyre-settings-button{opacity:0!important;pointer-events:none!important;}' +
                        '.tyre-settings-button{position:absolute;right:2px;bottom:2px;width:16px;height:13px;min-width:0;padding:0;border:1px solid rgba(255,255,255,.48);border-radius:4px;background:rgba(20,20,20,.72);color:#fff;font:bold 11px/7px Arial,sans-serif;letter-spacing:-1px;text-align:center;cursor:pointer;z-index:6;opacity:.82;}' +
                        '.tyre-settings-button:hover{opacity:1;background:rgba(45,45,45,.92);}' +
                        '.tyre-settings-panel{position:fixed;right:14px;bottom:14px;width:340px;max-width:calc(100vw - 28px);max-height:calc(100vh - 28px);display:flex;flex-direction:column;z-index:100000;border:1px solid rgba(255,255,255,.3);border-radius:9px;background:rgba(18,20,24,.97);box-shadow:0 8px 28px rgba(0,0,0,.55);color:#fff;font:11px Arial,sans-serif;overflow:hidden;}' +
                        '.tyre-settings-panel[hidden]{display:none!important;}' +
                        '.tyre-settings-header{display:flex;align-items:center;gap:8px;padding:7px 8px;border-bottom:1px solid rgba(255,255,255,.16);background:rgba(255,255,255,.055);}' +
                        '.tyre-settings-title{flex:1;font-weight:bold;font-size:12px;}' +
                        '.tyre-settings-close,.tyre-reset-all,.tyre-setting-reset{border:1px solid rgba(255,255,255,.28);background:rgba(255,255,255,.08);color:#fff;border-radius:4px;cursor:pointer;}' +
                        '.tyre-settings-close{width:22px;height:20px;padding:0;font-size:14px;line-height:16px;}' +
                                                '.tyre-settings-body{overflow-y:auto;padding:6px 8px 8px;}' +
                        '.tyre-profile-card{box-sizing:border-box;margin:0 0 8px;padding:6px 7px;border:1px solid rgba(120,205,255,.28);border-radius:5px;background:rgba(65,135,180,.10);overflow:hidden;}' +
                        '.tyre-profile-heading{height:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:bold;color:rgba(170,225,255,.98);margin-bottom:4px;}' +
                        '.tyre-profile-line{display:flex;flex-direction:column;gap:4px;color:rgba(255,255,255,.82);}' +
                        '.tyre-profile-entry{min-width:0;padding-top:4px;border-top:1px solid rgba(255,255,255,.09);}' +
                        '.tyre-profile-entry:first-child{padding-top:0;border-top:0;}' +
                        '.tyre-profile-entry-top{display:grid;grid-template-columns:auto minmax(0,1fr) auto;align-items:center;gap:5px;min-width:0;height:14px;}' +
                        '.tyre-profile-wheels{font-weight:bold;color:rgba(255,255,255,.92);white-space:nowrap;}' +
                        '.tyre-profile-kind{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:rgba(175,225,255,.94);}' +
                        '.tyre-profile-source{padding:0 3px;border:1px solid rgba(255,255,255,.14);border-radius:3px;color:rgba(255,255,255,.52);font-size:8px;line-height:11px;white-space:nowrap;}' +
                        '.tyre-profile-part{height:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:rgba(255,255,255,.68);font:9px/13px Consolas,monospace;}' +
                        '.tyre-profile-stats{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px;margin-top:3px;}' +
                        '.tyre-profile-stat{min-width:0;padding:2px 1px;border-radius:3px;background:rgba(0,0,0,.17);text-align:center;}' +
                        '.tyre-profile-stat-label{display:block;overflow:hidden;color:rgba(255,255,255,.43);font-size:7px;line-height:8px;letter-spacing:.25px;white-space:nowrap;}' +
                        '.tyre-profile-stat-value{display:block;overflow:hidden;text-overflow:ellipsis;color:rgba(255,255,255,.88);font:bold 9px/11px Consolas,monospace;white-space:nowrap;}' +
                        '.tyre-profile-struct-input{box-sizing:border-box;width:100%;height:12px;margin:0;padding:0 1px;border:1px solid rgba(255,255,255,.16);border-radius:2px;background:rgba(0,0,0,.18);color:rgba(255,255,255,.88);font:bold 8px/10px Consolas,monospace;text-align:center;outline:none;}' +
                        '.tyre-profile-struct-input.manual{border-color:rgba(255,176,70,.75);background:rgba(180,88,20,.24);color:#fff;}' +
                        '.tyre-profile-struct-input:focus{border-color:rgba(130,205,255,.95);background:rgba(0,0,0,.55);}' +
                        '.tyre-profile-note{height:12px;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:rgba(255,255,255,.52);font-size:9px;line-height:12px;}' +
                        '.tyre-active-thermal{margin-top:5px;padding:5px 6px;border:1px solid rgba(110,220,180,.22);border-radius:4px;background:rgba(30,120,90,.08);color:rgba(255,255,255,.78);font:8px/12px Consolas,monospace;white-space:pre-wrap;}' +
                        '.tyre-profile-presets{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px;margin-top:6px;}' +
                        '.tyre-compound-section[hidden]{display:none!important;}' +
                        '.tyre-slick-heading{margin-top:6px;color:rgba(255,255,255,.62);font:bold 8px Arial,sans-serif;letter-spacing:.5px;}' +
                        '.tyre-slick-presets{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:4px;margin-top:3px;}' +
                        '.tyre-rally-surface-presets{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:4px;margin-top:3px;}' +
                        '.tyre-slick-preset{height:25px;min-width:0;padding:0 3px;border:1px solid rgba(255,255,255,.22);border-radius:4px;background:rgba(255,255,255,.06);color:rgba(255,255,255,.82);font:bold 9px Arial,sans-serif;cursor:pointer;}' +
                        '.tyre-slick-preset:hover{background:rgba(255,255,255,.14);}' +
                        '.tyre-slick-preset.active{border-color:rgba(255,205,75,.95);background:rgba(170,125,20,.62);color:#fff;}' +
                        '.tyre-profile-preset{height:23px;min-width:0;padding:0 3px;border:1px solid rgba(255,255,255,.24);border-radius:4px;background:rgba(255,255,255,.08);color:rgba(255,255,255,.85);font:bold 9px Arial,sans-serif;cursor:pointer;}' +
                        '.tyre-profile-preset:hover{background:rgba(255,255,255,.16);}' +
                        '.tyre-profile-preset.active{border-color:rgba(255,170,55,.95);background:rgba(220,115,20,.65);color:#fff;}' +
                        '.tyre-preheat-row{display:flex;align-items:stretch;gap:5px;margin-top:5px;}' +
                        '.tyre-preheat-button{flex:1;min-width:0;height:28px;margin:0;padding:0 7px;border:1px solid rgba(255,190,80,.72);border-radius:4px;background:rgba(190,92,18,.58);color:#fff;font:bold 10px Arial,sans-serif;letter-spacing:.2px;cursor:pointer;}' +
                        '.tyre-preheat-button:hover{background:rgba(225,118,24,.78);border-color:rgba(255,215,135,.9);}' +
                        '.tyre-preheat-button:active{transform:translateY(1px);}' +
                        '.tyre-preheat-button.preheat-soaked{border-color:rgba(255,115,65,.88);background:rgba(165,48,24,.68);}' +
                        '.tyre-preheat-button.preheat-cold{border-color:rgba(115,205,255,.78);background:rgba(28,72,98,.66);}' +
                        '.tyre-preheat-temp-wrap{display:flex;align-items:center;min-width:76px;height:28px;box-sizing:border-box;border:1px solid rgba(255,190,80,.52);border-radius:4px;background:rgba(55,38,20,.62);overflow:hidden;}' +
                        '.tyre-preheat-temp-input{box-sizing:border-box;width:54px;height:26px;padding:0 3px;border:0;background:transparent;color:#fff;font:bold 10px Consolas,monospace;text-align:right;outline:none;}' +
                        '.tyre-preheat-temp-input:focus{background:rgba(0,0,0,.26);}' +
                        '.tyre-preheat-temp-unit{padding:0 4px 0 1px;color:rgba(255,225,185,.82);font:bold 9px Arial,sans-serif;}' +
                        '.tyre-preheat-advanced-toggle{width:100%;height:22px;margin-top:4px;padding:0 7px;border:1px solid rgba(255,198,92,.30);border-radius:4px;background:rgba(75,55,25,.22);color:rgba(255,225,180,.86);font:bold 8px Arial,sans-serif;letter-spacing:.45px;cursor:pointer;}' +
                        '.tyre-preheat-advanced-toggle.active{border-color:rgba(255,205,90,.72);background:rgba(125,82,22,.30);color:#fff;}' +
                        '.tyre-preheat-advanced-panel{margin-top:4px;padding:6px;border:1px solid rgba(255,200,90,.34);border-radius:5px;background:rgba(48,35,18,.34);}' +
                        '.tyre-preheat-advanced-panel[hidden]{display:none!important;}' +
                        '.tyre-preheat-advanced-title{display:flex;align-items:center;justify-content:space-between;gap:5px;margin-bottom:5px;color:rgba(255,226,180,.90);font:bold 8px Arial,sans-serif;letter-spacing:.5px;}' +
                        '.tyre-preheat-global-reset{height:20px;padding:0 6px;border:1px solid rgba(255,255,255,.22);border-radius:3px;background:rgba(255,255,255,.06);color:rgba(255,255,255,.76);font:bold 7px Arial,sans-serif;cursor:pointer;}' +
                        '.tyre-preheat-link-row{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px;margin-bottom:6px;}' +
                        '.tyre-preheat-link{height:24px;padding:0 4px;border:1px solid rgba(95,230,125,.25);border-radius:4px;background:rgba(30,90,45,.12);color:rgba(215,255,220,.72);font:bold 8px Arial,sans-serif;cursor:pointer;}' +
                        '.tyre-preheat-link.active{border-color:rgba(70,245,110,.90);background:rgba(30,145,55,.45);color:#fff;box-shadow:inset 0 0 8px rgba(80,255,120,.10);}' +
                        '.tyre-preheat-corner-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px;transition:all .12s ease;}' +
                        '.tyre-preheat-corner-grid.mode-corners{grid-template-rows:auto auto;}' +
                        '.tyre-preheat-corner-grid.mode-lr{grid-template-columns:repeat(2,minmax(0,1fr));grid-auto-rows:auto;}' +
                        '.tyre-preheat-corner-grid.mode-lr .tyre-preheat-corner-box{grid-column:1 / -1;min-height:38px;display:flex;align-items:center;justify-content:space-between;padding:5px 9px;}' +
                        '.tyre-preheat-corner-grid.mode-lr .tyre-preheat-corner-label{margin:0;text-align:left;font-size:8px;}' +
                        '.tyre-preheat-corner-grid.mode-lr .tyre-preheat-corner-input{width:70px;}' +
                        '.tyre-preheat-corner-grid.mode-fr{grid-template-columns:repeat(2,minmax(0,1fr));grid-template-rows:repeat(2,34px);}' +
                        '.tyre-preheat-corner-grid.mode-fr .tyre-preheat-corner-box{grid-row:1 / span 2;min-height:68px;display:flex;flex-direction:column;align-items:stretch;justify-content:center;padding:6px 4px;}' +
                        '.tyre-preheat-corner-grid.mode-fr .tyre-preheat-corner-box:nth-child(1){grid-column:1;}' +
                        '.tyre-preheat-corner-grid.mode-fr .tyre-preheat-corner-box:nth-child(2){grid-column:2;}' +
                        '.tyre-preheat-corner-grid.mode-fr .tyre-preheat-corner-label{margin-bottom:7px;font-size:8px;}' +
                        '.tyre-preheat-corner-grid.mode-fr .tyre-preheat-corner-input{width:58px;height:28px;font-size:11px;}' +
                        '.tyre-preheat-corner-box{min-width:0;padding:4px;border:1px solid rgba(255,193,70,.48);border-radius:5px;background:rgba(100,66,18,.20);transition:min-height .12s ease,padding .12s ease;}' +
                        '.tyre-preheat-corner-label{display:block;margin-bottom:2px;color:rgba(255,224,170,.82);font:bold 7px Arial,sans-serif;text-align:center;letter-spacing:.4px;}' +
                        '.tyre-preheat-corner-input-wrap{display:flex;align-items:center;justify-content:center;gap:2px;}' +
                        '.tyre-preheat-corner-input{width:48px;height:22px;box-sizing:border-box;border:1px solid rgba(255,198,78,.52);border-radius:3px;background:rgba(42,31,16,.78);color:#fff;font:bold 10px Consolas,monospace;text-align:center;outline:none;}' +
                        '.tyre-preheat-corner-input:focus{border-color:rgba(255,225,120,.92);background:rgba(30,24,14,.92);}' +
                        '.tyre-preheat-corner-unit{color:rgba(255,224,175,.72);font:bold 8px Arial,sans-serif;}' +
                        '.tyre-preheat-advanced-note{margin-top:5px;color:rgba(255,255,255,.50);font:7px/10px Arial,sans-serif;text-align:center;}' +
                        '.tyre-racing-mode-toggle{width:100%;height:28px;margin:0 0 5px;padding:0 8px;border:1px solid rgba(255,174,70,.55);border-radius:5px;background:rgba(110,65,18,.24);color:rgba(255,220,175,.95);font:bold 10px Arial,sans-serif;letter-spacing:.6px;cursor:pointer;}' +
                        '.tyre-racing-mode-toggle:hover{background:rgba(165,92,20,.34);border-color:rgba(255,190,90,.86);}' +
                        '.tyre-racing-mode-toggle.active{background:linear-gradient(100deg,rgba(190,88,18,.78),rgba(120,67,20,.70));border-color:rgba(255,176,65,.96);color:#fff;box-shadow:inset 0 0 12px rgba(255,150,45,.12);}' +
                        '.tyre-pit-progress{position:relative;box-sizing:border-box;width:100%;height:22px;margin:0 0 5px;border:1px solid rgba(255,165,55,.92);border-radius:5px;background:rgba(30,24,16,.78);overflow:hidden;transition:opacity .18s,border-color .12s;}' +
                        '.tyre-pit-progress[hidden]{display:none!important;}' +
                        '.tyre-pit-progress.idle{opacity:1;}' +
                        '.tyre-pit-progress-fill{position:absolute;left:0;top:0;bottom:0;width:0;background:linear-gradient(90deg,rgba(220,104,18,.90),rgba(255,156,38,.92));transition:width .08s linear,background .12s;}' +
                        '.tyre-pit-progress-text{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#fff;font:bold 9px Arial,sans-serif;letter-spacing:.55px;text-shadow:0 1px 2px rgba(0,0,0,.95);white-space:nowrap;z-index:2;}' +
                        '.tyre-pit-progress.finished,.tyre-pit-progress.ready{border-color:rgba(90,240,255,.95);}' +
                        '.tyre-pit-progress.finished .tyre-pit-progress-fill,.tyre-pit-progress.ready .tyre-pit-progress-fill{background:linear-gradient(90deg,rgba(20,175,195,.94),rgba(75,230,245,.96));}' +
                        '@keyframes tyrePitReject{0%,49.999%{background-color:rgba(240,120,18,.96);border-color:rgba(255,180,55,.98)}50%,100%{background-color:rgba(190,20,18,.98);border-color:rgba(255,65,55,.98)}}' +
                        '.tyre-pit-progress.reject{animation:tyrePitReject .5s steps(1,end) infinite;}' +
                        '.tyre-pit-progress.reject .tyre-pit-progress-fill{width:100%!important;background:transparent!important;}' +
                        '.tyre-pit-stop-button{width:100%;height:31px;margin-top:5px;padding:0 8px;border:1px solid rgba(255,182,65,.90);border-radius:5px;background:linear-gradient(100deg,rgba(185,78,15,.82),rgba(125,60,18,.82));color:#fff;font:bold 11px Arial,sans-serif;letter-spacing:.8px;cursor:pointer;}' +
                        '.tyre-pit-stop-button[hidden]{display:none!important;}' +
                        '.tyre-pit-stop-button:hover{background:linear-gradient(100deg,rgba(225,105,20,.92),rgba(165,78,18,.90));}' +
                        '.tyre-pit-stop-button:disabled{cursor:default;opacity:.50;}' +
                        '.tyre-pit-pressure-heading{margin:5px 0 3px;color:rgba(255,255,255,.62);font:bold 8px Arial,sans-serif;letter-spacing:.5px;}' +
                        '.tyre-pit-pressure-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px;margin:0 0 5px;}' +
                        '.tyre-pit-pressure-box{display:grid;grid-template-columns:1fr;gap:2px;min-width:0;}' +
                        '.tyre-pit-pressure-label{color:rgba(255,255,255,.58);font:bold 8px Arial,sans-serif;text-align:center;}' +
                        '.tyre-pit-pressure-input{box-sizing:border-box;width:100%;height:24px;padding:0 5px;border:1px solid rgba(120,205,255,.45);border-radius:4px;background:rgba(25,55,72,.36);color:#fff;font:bold 10px Consolas,monospace;text-align:center;outline:none;}' +
                        '.tyre-pit-pressure-input:focus{border-color:rgba(120,225,255,.95);background:rgba(20,62,82,.72);}' +
                        '.tyre-pit-pressure-input.staged{border-color:rgba(255,170,55,.85);background:rgba(145,72,18,.32);}' +
                        '.tyre-arcade-mode-button{position:relative;pointer-events:auto!important;touch-action:manipulation;user-select:none;-webkit-user-select:none;width:100%;height:34px;margin:6px 0 7px;padding:0 9px;border:1px solid rgba(105,220,255,.55);border-radius:7px;background:linear-gradient(110deg,rgba(18,62,82,.92),rgba(25,36,66,.92));box-shadow:inset 0 0 12px rgba(75,205,255,.08),0 2px 8px rgba(0,0,0,.28);color:rgba(220,245,255,.96);font:bold 10px Arial,sans-serif;letter-spacing:.7px;cursor:pointer;overflow:hidden;transition:background .16s,border-color .16s,box-shadow .16s,transform .08s;}' +
                        '.tyre-arcade-mode-button:hover{border-color:rgba(150,235,255,.9);box-shadow:inset 0 0 16px rgba(75,205,255,.15),0 0 10px rgba(70,190,255,.18);}' +
                        '.tyre-arcade-mode-button:active{transform:translateY(1px);}' +
                        '.tyre-arcade-mode-button.mode-error{border-color:#ff4545!important;box-shadow:0 0 14px rgba(255,40,40,.75)!important;}' +
                        '.tyre-arcade-mode-button.active{border-color:rgba(255,158,74,.95);background:linear-gradient(110deg,rgba(236,68,118,.90),rgba(238,116,34,.92) 56%,rgba(255,190,48,.90));box-shadow:inset 0 0 18px rgba(255,255,255,.13),0 0 14px rgba(255,105,55,.38);color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.55);}' +
                        '.tyre-arcade-mode-button .mode-main{display:block;font-size:11px;line-height:14px;}' +
                        '.tyre-arcade-mode-button .mode-sub{display:block;font:8px/10px Arial,sans-serif;letter-spacing:.2px;opacity:.74;}' +
                        '.tyre-advanced-toggle{width:100%;height:25px;margin:0 0 7px;padding:0 7px;border:1px solid rgba(130,205,255,.34);border-radius:4px;background:rgba(65,135,180,.10);color:rgba(205,235,255,.94);font:bold 10px Arial,sans-serif;letter-spacing:.35px;cursor:pointer;text-align:left;}' +
                        '.tyre-advanced-toggle:hover{background:rgba(75,150,195,.18);border-color:rgba(150,220,255,.55);}' +
                        '.tyre-advanced-content[hidden]{display:none!important;}' +
                        '.tyre-settings-group{margin:0 0 8px;}' +
                        '.tyre-settings-group-title{margin:4px 0 3px;padding-bottom:2px;border-bottom:1px solid rgba(255,255,255,.13);font-weight:bold;color:rgba(255,255,255,.82);}' +
                        '.tyre-structure-tuner-status{margin:3px 0 5px;padding:5px 6px;border:1px solid rgba(255,255,255,.14);border-radius:4px;background:rgba(255,255,255,.04);color:rgba(255,255,255,.76);font:10px/1.35 Consolas,monospace;white-space:normal;}' +
                        '.tyre-setting-row{display:grid;grid-template-columns:minmax(0,1fr) auto 25px;align-items:center;gap:5px;min-height:25px;}' +
                        '.tyre-setting-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:rgba(255,255,255,.9);}' +
                        '.tyre-setting-input{box-sizing:border-box;width:100%;height:21px;padding:1px 5px;border:1px solid rgba(255,255,255,.25);border-radius:3px;background:rgba(0,0,0,.34);color:#fff;font:11px Consolas,monospace;outline:none;text-align:right;}' +
                        '.tyre-setting-input:focus{border-color:rgba(130,205,255,.9);background:rgba(0,0,0,.52);}' +
                        '.tyre-setting-input.invalid{border-color:#ff7777;background:rgba(120,0,0,.28);}' +
                        '.tyre-setting-range-wrap{display:grid;grid-template-columns:minmax(0,1fr) 31px;align-items:center;gap:3px;width:88px;}' +
                        '.tyre-setting-percent-wrap{display:grid;grid-template-columns:30px 12px;align-items:center;gap:1px;width:43px;min-width:43px;max-width:43px;overflow:hidden;}' +
                        '.tyre-setting-percent-wrap .tyre-setting-input{width:30px;min-width:0;max-width:30px;padding:1px 2px;font-size:9.5px;text-align:right;overflow:hidden;}' +
                        '.tyre-setting-percent-unit{display:flex;align-items:center;justify-content:center;width:12px;min-width:12px;max-width:12px;height:21px;overflow:hidden;border:1px solid rgba(255,255,255,.13);border-radius:3px;background:rgba(255,255,255,.05);color:rgba(215,240,255,.9);font:9px Arial,sans-serif;box-sizing:border-box;}' +
                        '.tyre-setting-native-unit-wrap{display:grid;grid-template-columns:60px auto;align-items:center;gap:3px;width:78px;min-width:78px;max-width:78px;overflow:hidden;justify-self:end;}' +
                        '.tyre-setting-native-unit-wrap .tyre-setting-input{width:60px;min-width:60px;max-width:60px;padding-right:5px;font-size:11px;text-align:right;}' +
                        '.tyre-setting-native-unit{display:flex;align-items:center;justify-content:center;min-width:15px;max-width:15px;height:21px;overflow:hidden;border:1px solid rgba(255,255,255,.13);border-radius:3px;background:rgba(255,255,255,.05);color:rgba(215,240,255,.9);font:9px Arial,sans-serif;box-sizing:border-box;padding:0 2px;}' +
                        '.tyre-setting-native-value{width:60px!important;min-width:60px!important;max-width:60px!important;padding-right:5px!important;text-align:right!important;}' +
                        '.tyre-setting-range{width:100%;min-width:0;margin:0;accent-color:#67d5ff;cursor:pointer;}' +
                        '.tyre-setting-range-value{font:9px Consolas,monospace;color:rgba(215,240,255,.92);text-align:right;white-space:nowrap;}' +
                        '.tyre-setting-checkbox{justify-self:end;width:18px;height:18px;margin:0 4px 0 0;accent-color:#67d5ff;cursor:pointer;}' +
                        '.tyre-setting-reset{width:25px;height:21px;padding:0;font-size:14px;line-height:16px;}' +
                        '.tyre-setting-reset:hover,.tyre-settings-close:hover,.tyre-reset-all:hover{background:rgba(255,255,255,.16);}' +
                        '.tyre-setting-row.auto-readonly{opacity:.55;}' +
                        '.tyre-setting-row.auto-readonly .tyre-setting-input,.tyre-setting-row.auto-readonly .tyre-setting-reset{cursor:not-allowed;}' +
                        '.tyre-setting-row.live-tread-readonly{opacity:.62;}' +
                        '.tyre-setting-row.live-tread-readonly .tyre-setting-range,.tyre-setting-row.live-tread-readonly .tyre-setting-reset{cursor:not-allowed;filter:saturate(.35);}' +
                        '.tyre-settings-footer{display:flex;align-items:center;gap:7px;padding:6px 8px;border-top:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.035);}' +
                        '.tyre-reset-all{height:22px;padding:0 7px;font-size:11px;}' +
                        '.tyre-settings-status{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:rgba(255,255,255,.65);text-align:right;}' +
                        '.tyre-keypad{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:4px;padding:6px 8px;border-top:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.16);}' +
                        '.tyre-keypad-button{height:25px;min-width:0;padding:0;border:1px solid rgba(255,255,255,.24);border-radius:4px;background:rgba(255,255,255,.08);color:#fff;font:12px Arial,sans-serif;cursor:pointer;}' +
                        '.tyre-keypad-button:hover{background:rgba(255,255,255,.17);}' +
                        '.tyre-keypad-button.apply{background:rgba(40,115,70,.72);border-color:rgba(130,255,175,.55);}' +
                        '.tyre-debug-fullscreen{position:fixed;inset:0;z-index:99990;overflow:hidden;pointer-events:none;background:transparent;color:#fff;font-family:Arial,sans-serif;text-shadow:0 1px 3px rgba(0,0,0,.98),0 0 7px rgba(0,0,0,.88);}' +
                        '.tyre-debug-fullscreen[hidden]{display:none!important;}' +
                        '.tyre-debug-fullscreen-hint{position:absolute;top:1.4vh;left:50%;transform:translateX(-50%);color:rgba(185,235,255,.82);font:bold clamp(10px,.72vw,14px) Arial,sans-serif;letter-spacing:.12em;white-space:nowrap;}' +
                        '.tyre-debug-fullscreen-wheel{position:absolute;width:43vw;height:47vh;transform:translate(-50%,-50%);display:grid;grid-template-columns:clamp(82px,7.2vw,138px) minmax(0,1fr);align-items:center;column-gap:clamp(10px,1.2vw,24px);box-sizing:border-box;}' +
                        '.tyre-debug-fullscreen-wheel.front-left{left:25%;top:25%;}' +
                        '.tyre-debug-fullscreen-wheel.front-right{left:75%;top:25%;}' +
                        '.tyre-debug-fullscreen-wheel.rear-left{left:25%;top:75%;}' +
                        '.tyre-debug-fullscreen-wheel.rear-right{left:75%;top:75%;}' +
                        '.tyre-debug-fullscreen-wheel.front-left,.tyre-debug-fullscreen-wheel.rear-left{grid-template-columns:minmax(0,1fr) clamp(82px,7.2vw,138px);}' +
                        '.tyre-debug-fullscreen-tyre{position:relative;justify-self:center;width:100%;height:clamp(150px,24vh,240px);box-sizing:border-box;border:2px solid rgba(220,245,255,.92);border-radius:clamp(11px,1.1vw,22px);background:rgba(3,7,10,.32);box-shadow:0 0 10px rgba(0,0,0,.68),inset 0 0 16px rgba(0,0,0,.42);overflow:hidden;}' +
                        '.tyre-debug-fullscreen-wheel.front-left>.tyre-debug-fullscreen-tyre,.tyre-debug-fullscreen-wheel.rear-left>.tyre-debug-fullscreen-tyre{grid-column:2;grid-row:1;}' +
                        '.tyre-debug-fullscreen-tyre-head{position:absolute;z-index:3;left:0;right:0;top:0;height:18%;display:flex;align-items:center;justify-content:space-between;box-sizing:border-box;padding:0 9%;border-bottom:1px solid rgba(220,245,255,.74);font:bold clamp(11px,.9vw,17px) "Lucida Console",Monaco,monospace;}' +
                        '.tyre-debug-fullscreen-tread{position:absolute;left:0;right:0;top:18%;bottom:0;display:grid;grid-template-columns:repeat(3,1fr);align-items:start;column-gap:2px;padding:2px;box-sizing:border-box;}' +
                        '.tyre-debug-fullscreen-strip{display:flex;flex-direction:column;align-self:start;width:100%;min-height:4%;overflow:hidden;box-sizing:border-box;border-bottom:1px solid rgba(255,255,255,.32);border-radius:0 0 4px 4px;box-shadow:inset 0 0 8px rgba(0,0,0,.28);transition:height .08s linear;}' +
                        '.tyre-debug-fullscreen-layer{display:block;flex:1 1 0;min-height:0;width:100%;box-sizing:border-box;border-bottom:1px solid rgba(235,250,255,.17);}' +
                        '.tyre-debug-fullscreen-layer:last-child{border-bottom:0;}' +
                        '.tyre-debug-fullscreen-pressure{position:absolute;z-index:4;left:50%;top:57%;transform:translate(-50%,-50%);min-width:62%;box-sizing:border-box;padding:5% 4%;border:1px solid rgba(235,250,255,.88);border-radius:7px;background:rgba(0,0,0,.42);color:#fff;text-align:center;font:bold clamp(10px,.82vw,16px) "Lucida Console",Monaco,monospace;white-space:nowrap;}' +
                        '.tyre-debug-fullscreen-values{min-width:0;max-height:46vh;overflow:hidden;font-size:clamp(9px,.60vw,12px);line-height:1.03;}' +
                        '.tyre-debug-fullscreen-wheel.front-left>.tyre-debug-fullscreen-values,.tyre-debug-fullscreen-wheel.rear-left>.tyre-debug-fullscreen-values{grid-column:1;grid-row:1;text-align:right;}' +
                        '.tyre-debug-fullscreen-title{margin:0 0 .45vh;color:#fff;font:bold clamp(15px,1.22vw,23px) Arial,sans-serif;letter-spacing:.06em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}' +
                        '.tyre-debug-fullscreen-subtitle{margin:0 0 .55vh;color:rgba(180,225,245,.86);font:clamp(9px,.66vw,13px) Arial,sans-serif;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}' +
                        '.tyre-debug-fullscreen-group{margin:.30vh 0 0;}' +
                        '.tyre-debug-fullscreen-group-title{margin:0 0 .12vh;padding-bottom:.10vh;border-bottom:1px solid rgba(150,225,255,.36);color:rgba(130,220,255,.94);font:bold clamp(9px,.58vw,11px) Arial,sans-serif;letter-spacing:.10em;}' +
                        '.tyre-debug-fullscreen-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;min-height:1.12em;align-items:baseline;}' +
                        '.tyre-debug-fullscreen-label{min-width:0;color:rgba(246,250,252,.90);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
                        '.tyre-debug-fullscreen-value{color:#fff;font:bold 1em "Lucida Console",Monaco,monospace;text-align:right;white-space:nowrap;}' +
                        '.tyre-debug-fullscreen-wheel.front-left .tyre-debug-fullscreen-row,.tyre-debug-fullscreen-wheel.rear-left .tyre-debug-fullscreen-row{grid-template-columns:auto minmax(0,1fr);}' +
                        '.tyre-debug-fullscreen-wheel.front-left .tyre-debug-fullscreen-label,.tyre-debug-fullscreen-wheel.rear-left .tyre-debug-fullscreen-label{grid-column:2;grid-row:1;text-align:right;}' +
                        '.tyre-debug-fullscreen-wheel.front-left .tyre-debug-fullscreen-value,.tyre-debug-fullscreen-wheel.rear-left .tyre-debug-fullscreen-value{grid-column:1;grid-row:1;text-align:left;}' +
                        '.tyre-debug-fullscreen-value.emphasis{color:rgba(255,214,112,1);}' +
                        '@media (max-height:720px){.tyre-debug-fullscreen-wheel{height:48vh;}.tyre-debug-fullscreen-tyre{height:clamp(126px,23vh,176px);}.tyre-debug-fullscreen-values{max-height:47vh;font-size:8.5px;line-height:1.0;}.tyre-debug-fullscreen-group{margin:.12vh 0 0;}.tyre-debug-fullscreen-group-title{font-size:8px;}.tyre-debug-fullscreen-row{min-height:1.02em;}.tyre-debug-fullscreen-title{font-size:13px;margin-bottom:1px;}.tyre-debug-fullscreen-subtitle{font-size:8px;margin-bottom:1px;}}' +
                    '</style>' +
                    '<canvas width="220" height="220"></canvas>' +
                    '<button type="button" class="tyre-settings-button" title="Tyre model tuning" aria-label="Open tyre model tuning" style="display:none">⋯</button>' +
                    '<section class="tyre-settings-panel" hidden aria-label="Tyre model tuning panel">' +
                        '<div class="tyre-settings-header">' +
                            '<div class="tyre-settings-title">Tyre model tuning</div>' +
                            '<button type="button" class="tyre-settings-close" title="Close">×</button>' +
                        '</div>' +
                        '<div class="tyre-settings-body"></div>' +
                        '<div class="tyre-keypad" aria-label="Numeric keypad">' +
                            '<button type="button" class="tyre-keypad-button" data-key="7">7</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="8">8</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="9">9</button>' +
                            '<button type="button" class="tyre-keypad-button" data-action="backspace">⌫</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="4">4</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="5">5</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="6">6</button>' +
                            '<button type="button" class="tyre-keypad-button" data-action="clear">C</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="1">1</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="2">2</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="3">3</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="-">−</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key="0">0</button>' +
                            '<button type="button" class="tyre-keypad-button" data-key=".">.</button>' +
                            '<button type="button" class="tyre-keypad-button" data-action="select-all">All</button>' +
                            '<button type="button" class="tyre-keypad-button apply" data-action="apply">✓</button>' +
                        '</div>' +
                        '<div class="tyre-settings-footer">' +
                            '<button type="button" class="tyre-reset-all">Reset all</button>' +
                            '<div class="tyre-settings-status">Physical keyboard or keypad</div>' +
                        '</div>' +
                    '</section>' +
                '</div>',
            replace: true,
            restrict: "EA",
            link: function (scope, element, attrs) {
                var root = element[0];
                var c = root.querySelector("canvas");
                var ctx = c.getContext("2d");
                var settingsButton = root.querySelector(".tyre-settings-button");
                var settingsPanel = root.querySelector(".tyre-settings-panel");
                var settingsClose = root.querySelector(".tyre-settings-close");
                var settingsBody = root.querySelector(".tyre-settings-body");
                var resetAllButton = root.querySelector(".tyre-reset-all");
                var settingsStatus = root.querySelector(".tyre-settings-status");
                var keypad = root.querySelector(".tyre-keypad");
                document.body.appendChild(settingsPanel);

                var fullscreenDebugOverlay = document.createElement("section");
                fullscreenDebugOverlay.className = "tyre-debug-fullscreen";
                fullscreenDebugOverlay.hidden = true;
                fullscreenDebugOverlay.setAttribute("aria-label", "Fullscreen tyre diagnostics");
                var fullscreenDebugHint = document.createElement("div");
                fullscreenDebugHint.className = "tyre-debug-fullscreen-hint";
                fullscreenDebugHint.textContent = "FULL TYRE DEBUG  ·  SYMMETRIC LIVE 12-CELL VIEW  ·  DOUBLE-CLICK OUTSIDE THE WEAR BUTTON OR PRESS ESC TO CLOSE";
                fullscreenDebugOverlay.appendChild(fullscreenDebugHint);
                document.body.appendChild(fullscreenDebugOverlay);

                var streamsList = ["TyreWearThermals"];
                var wearToggleBounds = null;
                var wheelClickBounds = [];
                var wearEnabled = false;
                var thermalsPaused = false;
                var debugTempsEnabled = false;
                var fullscreenDebugOpen = false;
                var fullscreenDebugWheelSlots = {};
                var fullscreenDebugLatestWheelData = [];
                var debugCanvasClickTimer = null;
                var debugCanvasClickCount = 0;
                var debugCanvasFirstClickPoint = null;
                var debugCanvasClickWindowMs = 500;
                var debugCanvasTripleGraceMs = 260;
                var debugTempCheckbox = null;
                var arcadeHandlingButton = null;
                var arcadeHandlingEnabled = false;
                var arcadeHandlingRevision = -1;
                var arcadeHandlingPendingRevision = -1;
                var arcadeHandlingPendingState = null;
                var arcadeHandlingAckTimer = null;
                var arcadeHandlingLastPressMs = 0;
                var wearClickTimer = null;
                var wearClickWindowMs = 300;
                var tuningInputs = {};
                var tuningResetButtons = {};
                var currentTuningValues = {};
                var nativeTuningValues = {};
                var tuningLabels = {};
                var tuningRows = {};
                var structureTunerStatus = null;
                var sportStiffnessStatus = null;
                var cefKeyboardCaptured = false;
                var keyboardCaptureTimer = null;
                var activeTuningInput = null;
                var activeTuningDefinition = null;
                var tyreProfileCard = null;
                var tyreProfileLines = null;
                var tyreProfileNote = null;
                var tyreActiveThermal = null;
                var tyreProfilePresetButtons = {};
                var currentTyreProfilePreset = "auto";
                var slickCompoundPresetButtons = {};
                var currentSlickCompoundPreset = "medium";
                var slickCompoundSection = null;
                var rallyCompoundSection = null;
                var rallySurfacePresetButtons = {};
                var rallyCompoundPresetButtons = {};
                var currentRallySurfacePreset = "asphalt";
                var currentRallyCompoundPreset = "medium";
                var appliedTyreProfilePreset = "auto";
                var appliedSlickCompoundPreset = "medium";
                var appliedRallySurfacePreset = "asphalt";
                var appliedRallyCompoundPreset = "medium";
                var racingModeEnabled = false;
                var racingModeButton = null;
                var preheatButton = null;
                var preheatTempInput = null;
                var preheatTempInitialised = false;
                var preheatTempUserEdited = false;
                var preheatUiMode = "quick";
                var lastAppliedPreheatPresetSignature = null;
                var advancedPreheatToggle = null;
                var advancedPreheatPanel = null;
                var advancedPreheatGrid = null;
                var advancedPreheatLinkLRButton = null;
                var advancedPreheatLinkFRButton = null;
                var advancedPreheatStorageKey = "kagoniAdvancedPreheatV1";
                var advancedPreheatState = {
                    custom: false, open: false, linkLR: false, linkFR: false,
                    temps: { FL: 70, FR: 70, RL: 70, RR: 70 }
                };
                var pitStopButton = null;
                var pitProgress = null;
                var pitProgressFill = null;
                var pitProgressText = null;
                var pitFrontPsiInput = null;
                var pitRearPsiInput = null;
                var pitPressureHeading = null;
                var pitTunedFrontPsi = null;
                var pitTunedRearPsi = null;
                var pitPendingPsi = { front: null, rear: null };
                var pitStopState = "off";
                var tyreProfileEntryElements = {};
                var tyreProfileStructureSignature = "";
                var structuralPsiStorageKey = "kagoniTyreStructuralPsiTargetsV1";
                var structuralPsiOverrides = {};
                var structuralPsiApplied = {};
                try {
                    structuralPsiOverrides = JSON.parse(localStorage.getItem(structuralPsiStorageKey) || "{}") || {};
                } catch (e) { structuralPsiOverrides = {}; }

                function fullscreenFiniteNumber(value, fallback) {
                    value = Number(value);
                    return isFinite(value) ? value : fallback;
                }

                function fullscreenClamp01(value) {
                    return Math.max(0, Math.min(1, fullscreenFiniteNumber(value, 0)));
                }

                function fullscreenFormat(value, digits, suffix, scale) {
                    value = Number(value);
                    if (!isFinite(value)) return "—";
                    value *= scale === undefined ? 1 : scale;
                    return value.toFixed(digits === undefined ? 2 : digits) + (suffix || "");
                }

                function fullscreenField(key, digits, suffix, scale) {
                    return function (wheelData) {
                        return fullscreenFormat(wheelData && wheelData[key], digits, suffix, scale);
                    };
                }

                function fullscreenFirstField(keys, digits, suffix, scale) {
                    return function (wheelData) {
                        wheelData = wheelData || {};
                        for (var i = 0; i < keys.length; i++) {
                            var value = Number(wheelData[keys[i]]);
                            if (isFinite(value)) return fullscreenFormat(value, digits, suffix, scale);
                        }
                        return "—";
                    };
                }

                function fullscreenSurfaceTriplet(wheelData) {
                    wheelData = wheelData || {};
                    var values = wheelData.surface_temp && wheelData.surface_temp.length >= 3
                        ? wheelData.surface_temp : wheelData.temp;
                    if (!values || values.length < 3) return "—";
                    var formatted = [];
                    for (var i = 0; i < 3; i++) {
                        var value = Number(values[i]);
                        formatted.push(isFinite(value) ? value.toFixed(1) : "—");
                    }
                    return formatted.join(" / ") + " °C";
                }

                function fullscreenDepthTriplet(wheelData) {
                    wheelData = wheelData || {};
                    var mean = Number(wheelData.tread_remaining_depth_mm);
                    var keys = ["tread_remaining_outer_mm", "tread_remaining_middle_mm", "tread_remaining_inner_mm"];
                    var formatted = [];
                    for (var i = 0; i < keys.length; i++) {
                        var value = Number(wheelData[keys[i]]);
                        if (!isFinite(value)) value = mean;
                        formatted.push(isFinite(value) ? Math.max(0, value).toFixed(2) : "—");
                    }
                    return formatted.join(" / ") + " mm";
                }

                function fullscreenLayerSource(wheelData) {
                    wheelData = wheelData || {};
                    var fields = [wheelData.tread_field_outer, wheelData.tread_field_middle, wheelData.tread_field_inner];
                    var minimumCount = Infinity;
                    for (var i = 0; i < fields.length; i++) {
                        if (!fields[i] || !fields[i].length) return "RECONSTRUCTED 12-CELL · CORE → ROAD";
                        minimumCount = Math.min(minimumCount, fields[i].length);
                    }
                    return minimumCount === 12
                        ? "LIVE 12-CELL FIELD · CORE → ROAD"
                        : "LIVE " + minimumCount + "-CELL FIELD · CORE → ROAD";
                }

                var fullscreenTreadStateGroup = {
                    title: "TREAD GRADIENT & WEAR",
                    rows: [
                        { key: "graphicThermalDepthSource", label: "Fullscreen tyre graphic thermal-depth source", value: fullscreenLayerSource, emphasis: true },
                        { key: "surfaceTemperatureTriplet", label: "Road-facing temperature — outside / middle / inside", value: fullscreenSurfaceTriplet },
                        { key: "overallWearHealth", label: "Overall wearable tread health", value: fullscreenField("condition", 1, "%"), emphasis: true },
                        { key: "remainingDepthTriplet", label: "Remaining depth — outside / middle / inside", value: fullscreenDepthTriplet, emphasis: true },
                        { key: "meanRemainingDepth", label: "Mean remaining tread depth", value: fullscreenField("tread_remaining_depth_mm", 2, " mm") },
                        { key: "nonWearableReserve", label: "Non-wearable belt / reserve depth", value: fullscreenField("tread_nonwearable_reserve_mm", 2, " mm") }
                    ]
                };

                var fullscreenRoadGroups = [
                    {
                        title: "THERMAL STATE",
                        rows: [
                            { key: "physicalSurfaceTemperature", label: "Physical road-facing surface temperature", value: fullscreenFirstField(["physical_surface_temp_c", "surface_avg_temp"], 1, " °C") },
                            { key: "bulkTreadTemperature", label: "Bulk tread temperature", value: fullscreenFirstField(["bulk_tread_avg_temp", "avg_temp"], 1, " °C") },
                            { key: "gripDepthTemperature", label: "Grip-active near-surface temperature", value: fullscreenFirstField(["surface_grip_temp_c", "grip_depth_avg_temp"], 1, " °C") },
                            { key: "coreTemperature", label: "Core and carcass temperature", value: fullscreenField("core_temp", 1, " °C") },
                            { key: "flashTemperature", label: "Microscopic contact flash temperature", value: fullscreenField("flash_temp", 1, " °C") }
                        ]
                    },
                    fullscreenTreadStateGroup,
                    {
                        title: "MODEL-OWNED ROAD GRIP / STRIBECK",
                        rows: [
                            { key: "roadCurveOwner", label: "Road friction-envelope owner", value: function (wd) { return wd && wd.model_curve_enabled === true ? "KAGONI MODEL" : "NATIVE / HANDOFF"; }, emphasis: true },
                            { key: "nativePatchRatio", label: "Predicted BeamNG native patch ratio", value: fullscreenField("native_dry_patch_ratio", 3, "") },
                            { key: "nativeUltimateRatio", label: "Predicted BeamNG ultimate sliding ratio", value: fullscreenField("native_dry_ultimate_ratio", 3, "") },
                            { key: "targetPatchRatio", label: "Model-owned target patch ratio", value: fullscreenField("model_curve_target_patch_ratio", 3, ""), emphasis: true },
                            { key: "commandedPatchRatio", label: "Model-commanded patch ratio", value: fullscreenField("model_curve_commanded_patch_ratio", 3, ""), emphasis: true },
                            { key: "mechanicalActuator", label: "Mechanical de-embedding actuator", value: fullscreenFirstField(["model_curve_correction_multiplier", "mechanical_grip_multiplier"], 3, "×"), emphasis: true },
                            { key: "correctedPatchRatio", label: "Predicted corrected road-patch ratio", value: function (wd) {
                                if (!wd) return "—";
                                var nativeRatio = Number(wd.native_dry_patch_ratio);
                                var actuator = Number(wd.model_curve_correction_multiplier);
                                if (!isFinite(actuator)) actuator = Number(wd.mechanical_grip_multiplier);
                                return isFinite(nativeRatio) && isFinite(actuator)
                                    ? fullscreenFormat(nativeRatio * actuator, 3, "") : "—";
                            }, emphasis: true },
                            { key: "macroGripMultiplier", label: "Macro temperature and wear multiplier", value: fullscreenField("macro_wear_grip_multiplier", 3, "×") },
                            { key: "finalGripScalar", label: "Final applied friction scalar", value: fullscreenFirstField(["total_model_grip_multiplier", "tyreGrip"], 3, "×"), emphasis: true }
                        ]
                    },
                    {
                        title: "SLIP, BRUSH & STRUCTURE",
                        rows: [
                            { key: "combinedSlipSpeed", label: "Wheel-centre combined slip speed", value: fullscreenFirstField(["flash_grip_slip_speed", "physical_slip_speed_mps"], 2, " m/s") },
                            { key: "longitudinalSlipSpeed", label: "Longitudinal slip speed", value: fullscreenField("slip_longitudinal_mps", 2, " m/s") },
                            { key: "lateralSlipSpeed", label: "Lateral slip speed", value: fullscreenField("slip_lateral_mps", 2, " m/s") },
                            { key: "wheelSurfaceSpeed", label: "Wheel tread surface speed", value: fullscreenField("flash_grip_surface_speed", 2, " m/s") },
                            { key: "slipAngle", label: "Kinematic slip angle", value: fullscreenField("kinematic_slip_angle_deg", 2, "°") },
                            { key: "slidingLengthFraction", label: "Sliding contact-patch length fraction", value: fullscreenField("brush_sliding_length_fraction", 1, "%", 100) },
                            { key: "slidingLoadFraction", label: "Sliding normal-load fraction", value: fullscreenField("brush_sliding_load_fraction", 1, "%", 100), emphasis: true },
                            { key: "criticalAngle", label: "Structure-calibrated full-slide angle", value: fullscreenField("brush_critical_angle_deg", 2, "°") },
                            { key: "normalLoad", label: "Wheel normal load", value: fullscreenField("wheel_normal_load_n", 0, " N") },
                            { key: "beamngLastSlip", label: "BeamNG last-slip signal (raw)", value: fullscreenField("beamng_last_slip", 3, "") },
                            { key: "beamngLastSideSlip", label: "BeamNG side-slip signal (raw)", value: fullscreenField("beamng_last_side_slip", 3, "") }
                        ]
                    }
                ];

                var fullscreenDirtGroups = [
                    {
                        title: "THERMAL STATE",
                        rows: [
                            { key: "dirtBlockTemperature", label: "Dirt-contact tread-block temperature", value: fullscreenField("rally_dirt_block_temp_c", 1, " °C") },
                            { key: "physicalSurfaceTemperature", label: "Physical road-facing surface temperature", value: fullscreenFirstField(["physical_surface_temp_c", "surface_avg_temp"], 1, " °C") },
                            { key: "bulkTreadTemperature", label: "Bulk tread temperature", value: fullscreenFirstField(["bulk_tread_avg_temp", "avg_temp"], 1, " °C") },
                            { key: "coreTemperature", label: "Core and carcass temperature", value: fullscreenField("core_temp", 1, " °C") },
                            { key: "flashTemperature", label: "Microscopic contact flash temperature", value: fullscreenField("flash_temp", 1, " °C") }
                        ]
                    },
                    fullscreenTreadStateGroup,
                    {
                        title: "EXCLUSIVE DIRT OVERLAY / TREAD BLOCKS",
                        rows: [
                            { key: "dirtRoute", label: "Active surface physics route", value: function (wd) { return wd && wd.rally_dirt_model_active === true ? "NATIVE TERRAIN + DIRT OVERLAY" : "ROAD MODEL"; }, emphasis: true },
                            { key: "dirtTemperatureGrip", label: "Dirt bulk-temperature grip multiplier", value: fullscreenField("rally_dirt_temp_multiplier", 3, "×") },
                            { key: "dirtFastHeatGrip", label: "Dirt fast-contact heat multiplier", value: fullscreenField("rally_dirt_fast_multiplier", 3, "×") },
                            { key: "dirtDirectionalWearGrip", label: "Directional block-wear grip multiplier", value: fullscreenField("rally_dirt_directional_wear_multiplier", 3, "×") },
                            { key: "dirtFinalOverlay", label: "Final rally dirt overlay multiplier", value: fullscreenField("rally_overlay_multiplier", 3, "×"), emphasis: true },
                            { key: "blockHeightHealth", label: "Tread-block height health", value: fullscreenField("rally_block_height_health", 1, "%", 100) },
                            { key: "activeEdgeHealth", label: "Currently active block-edge health", value: fullscreenField("rally_block_active_edge_health", 1, "%", 100), emphasis: true },
                            { key: "drivingEdgeHealth", label: "Driving-direction block face health (X+)", value: fullscreenField("rally_block_edge_xp", 1, "%", 100) },
                            { key: "brakingEdgeHealth", label: "Braking-direction block face health (X−)", value: fullscreenField("rally_block_edge_xn", 1, "%", 100) },
                            { key: "leftEdgeHealth", label: "Left-biting block face health (Y+)", value: fullscreenField("rally_block_edge_yp", 1, "%", 100) },
                            { key: "rightEdgeHealth", label: "Right-biting block face health (Y−)", value: fullscreenField("rally_block_edge_yn", 1, "%", 100) }
                        ]
                    },
                    {
                        title: "SLIP & CONTACT",
                        rows: [
                            { key: "combinedSlipSpeed", label: "Wheel-centre combined slip speed", value: fullscreenFirstField(["flash_grip_slip_speed", "physical_slip_speed_mps"], 2, " m/s") },
                            { key: "signedLongitudinalSlip", label: "Signed longitudinal slip speed", value: fullscreenField("rally_signed_longitudinal_slip_mps", 2, " m/s") },
                            { key: "signedLateralSlip", label: "Signed lateral slip speed", value: fullscreenField("rally_signed_lateral_slip_mps", 2, " m/s") },
                            { key: "slipAngle", label: "Kinematic slip angle", value: fullscreenField("kinematic_slip_angle_deg", 2, "°") },
                            { key: "slidingLoadFraction", label: "Sliding normal-load fraction", value: fullscreenField("brush_sliding_load_fraction", 1, "%", 100) },
                            { key: "normalLoad", label: "Wheel normal load", value: fullscreenField("wheel_normal_load_n", 0, " N") },
                            { key: "beamngLastSlip", label: "BeamNG last-slip signal (raw)", value: fullscreenField("beamng_last_slip", 3, "") },
                            { key: "beamngLastSideSlip", label: "BeamNG side-slip signal (raw)", value: fullscreenField("beamng_last_side_slip", 3, "") }
                        ]
                    }
                ];

                function createFullscreenDebugSlot(wheelName, positionClass) {
                    var slot = document.createElement("section");
                    slot.className = "tyre-debug-fullscreen-wheel " + positionClass;
                    slot.setAttribute("data-wheel", wheelName);

                    var tyre = document.createElement("div");
                    tyre.className = "tyre-debug-fullscreen-tyre";
                    var tyreHead = document.createElement("div");
                    tyreHead.className = "tyre-debug-fullscreen-tyre-head";
                    var tyreName = document.createElement("span");
                    tyreName.textContent = wheelName;
                    var tyreCondition = document.createElement("span");
                    tyreCondition.textContent = "—%";
                    tyreHead.appendChild(tyreName);
                    tyreHead.appendChild(tyreCondition);
                    tyre.appendChild(tyreHead);

                    var tread = document.createElement("div");
                    tread.className = "tyre-debug-fullscreen-tread";
                    var strips = [];
                    var stripLayers = [];
                    for (var i = 0; i < 3; i++) {
                        var strip = document.createElement("span");
                        strip.className = "tyre-debug-fullscreen-strip";
                        strip.style.height = "100%";
                        strip.style.backgroundColor = "rgba(90,180,220,.44)";
                        var layers = [];
                        for (var layerIndex = 0; layerIndex < 12; layerIndex++) {
                            var layer = document.createElement("span");
                            layer.className = "tyre-debug-fullscreen-layer";
                            layer.style.backgroundColor = "rgba(90,180,220,.44)";
                            strip.appendChild(layer);
                            layers.push(layer);
                        }
                        strips.push(strip);
                        stripLayers.push(layers);
                        tread.appendChild(strip);
                    }
                    tyre.appendChild(tread);
                    var pressure = document.createElement("div");
                    pressure.className = "tyre-debug-fullscreen-pressure";
                    pressure.textContent = "— PSI";
                    tyre.appendChild(pressure);
                    slot.appendChild(tyre);

                    var values = document.createElement("div");
                    values.className = "tyre-debug-fullscreen-values";
                    var title = document.createElement("div");
                    title.className = "tyre-debug-fullscreen-title";
                    title.textContent = wheelName + " — waiting";
                    var subtitle = document.createElement("div");
                    subtitle.className = "tyre-debug-fullscreen-subtitle";
                    subtitle.textContent = "Waiting for live wheel telemetry";
                    var list = document.createElement("div");
                    values.appendChild(title);
                    values.appendChild(subtitle);
                    values.appendChild(list);
                    slot.appendChild(values);
                    fullscreenDebugOverlay.appendChild(slot);

                    return {
                        root: slot,
                        tyre: tyre,
                        tyreHead: tyreHead,
                        tyreName: tyreName,
                        tyreCondition: tyreCondition,
                        strips: strips,
                        stripLayers: stripLayers,
                        pressure: pressure,
                        title: title,
                        subtitle: subtitle,
                        list: list,
                        rows: {},
                        mode: ""
                    };
                }

                fullscreenDebugWheelSlots.FL = createFullscreenDebugSlot("FL", "front-left");
                fullscreenDebugWheelSlots.FR = createFullscreenDebugSlot("FR", "front-right");
                fullscreenDebugWheelSlots.RL = createFullscreenDebugSlot("RL", "rear-left");
                fullscreenDebugWheelSlots.RR = createFullscreenDebugSlot("RR", "rear-right");

                function setFullscreenDebugRows(slot, groups, mode) {
                    if (!slot || slot.mode === mode) return;
                    slot.mode = mode;
                    slot.rows = {};
                    slot.list.textContent = "";
                    groups.forEach(function (group) {
                        var groupElement = document.createElement("section");
                        groupElement.className = "tyre-debug-fullscreen-group";
                        var groupTitle = document.createElement("div");
                        groupTitle.className = "tyre-debug-fullscreen-group-title";
                        groupTitle.textContent = group.title;
                        groupElement.appendChild(groupTitle);
                        group.rows.forEach(function (definition) {
                            var row = document.createElement("div");
                            row.className = "tyre-debug-fullscreen-row";
                            var label = document.createElement("span");
                            label.className = "tyre-debug-fullscreen-label";
                            label.textContent = definition.label;
                            var value = document.createElement("span");
                            value.className = "tyre-debug-fullscreen-value" + (definition.emphasis ? " emphasis" : "");
                            value.textContent = "—";
                            row.appendChild(label);
                            row.appendChild(value);
                            groupElement.appendChild(row);
                            slot.rows[definition.key] = value;
                        });
                        slot.list.appendChild(groupElement);
                    });
                }

                function fullscreenMixColor(a, b, t, alpha) {
                    t = fullscreenClamp01(t);
                    return "rgba(" +
                        Math.round(a[0] + (b[0] - a[0]) * t) + "," +
                        Math.round(a[1] + (b[1] - a[1]) * t) + "," +
                        Math.round(a[2] + (b[2] - a[2]) * t) + "," +
                        fullscreenClamp01(alpha).toFixed(3) + ")";
                }

                function temperatureMixColor(a, b, t) {
                    t = fullscreenClamp01(t);
                    return {
                        r: a.r + (b.r - a.r) * t,
                        g: a.g + (b.g - a.g) * t,
                        b: a.b + (b.b - a.b) * t,
                        a: a.a + (b.a - a.a) * t
                    };
                }

                function temperatureColorToRgbaString(color) {
                    return "rgba(" +
                        Math.round(color.r) + "," +
                        Math.round(color.g) + "," +
                        Math.round(color.b) + "," +
                        fullscreenClamp01(color.a).toFixed(3) + ")";
                }

                function fullscreenTemperatureColor(temperature, targetTemperature) {
                    var target = Math.max(Number(targetTemperature) || 0, 1);
                    var current = Number(temperature);
                    if (!isFinite(current)) current = target;

                    var deltaC = current - target;
                    var neutralColor = { r: 185, g: 190, b: 195, a: 0.0 };

                    if (deltaC >= 0) {
                        var faintYellow = { r: 236, g: 214, b: 102, a: 1.0 };
                        var solidYellow = { r: 198, g: 159, b: 16, a: 1.0 };
                        var solidOrange = { r: 198, g: 75, b: 16, a: 1.0 };
                        var orangeRed = { r: 198, g: 24, b: 16, a: 1.0 };
                        var red = { r: 255, g: 62, b: 42, a: 1.0 };

                        var hotColor;
                        if (deltaC < 8) {
                            hotColor = temperatureMixColor(
                                { r: 185, g: 190, b: 195, a: 1.0 },
                                faintYellow,
                                deltaC / 8
                            );
                        } else if (deltaC < 30) {
                            hotColor = temperatureMixColor(faintYellow, solidYellow, (deltaC - 8) / 22);
                        } else if (deltaC < 75) {
                            hotColor = temperatureMixColor(solidYellow, solidOrange, (deltaC - 30) / 45);
                        } else if (deltaC < 100) {
                            hotColor = temperatureMixColor(solidOrange, orangeRed, (deltaC - 75) / 25);
                        } else {
                            hotColor = temperatureMixColor(orangeRed, red, Math.min(1, (deltaC - 100) / 50));
                        }

                        hotColor.a = 0.06 + 0.94 * fullscreenClamp01(deltaC / 15);
                        return temperatureColorToRgbaString(hotColor);
                    }

                    var normalizedDelta = Math.max(-1, Math.min(0, deltaC / Math.max(target * 0.5, 20)));
                    var magnitude = Math.abs(normalizedDelta);
                    var neutralBand = 0.16;
                    if (magnitude <= neutralBand) {
                        return temperatureColorToRgbaString(neutralColor);
                    }

                    var intensity = fullscreenClamp01((magnitude - neutralBand) / (1 - neutralBand));
                    var coldStart = { r: 150, g: 232, b: 255, a: 0.52 };
                    var coldEnd = { r: 85, g: 220, b: 255, a: 0.96 };
                    var legacyColdColor = temperatureMixColor(coldStart, coldEnd, intensity);

                    var calibratedColdJoinC = target - 45;
                    if (current < calibratedColdJoinC) {
                        var joinDeltaC = calibratedColdJoinC - target;
                        var joinNormalizedDelta = Math.max(-1, Math.min(0, joinDeltaC / Math.max(target * 0.5, 20)));
                        var joinMagnitude = Math.abs(joinNormalizedDelta);
                        var joinIntensity = fullscreenClamp01((joinMagnitude - neutralBand) / (1 - neutralBand));
                        var joinColor = temperatureMixColor(coldStart, coldEnd, joinIntensity);
                        var deepColdColor = { r: 20, g: 55, b: 180, a: 1.0 };
                        var extremeColdT = fullscreenClamp01((current - 10) / Math.max(calibratedColdJoinC - 10, 1));
                        return temperatureColorToRgbaString(
                            temperatureMixColor(deepColdColor, joinColor, extremeColdT)
                        );
                    }

                    return temperatureColorToRgbaString(legacyColdColor);
                }

                function fullscreenConditionColor(condition) {
                    var wear = 1 - fullscreenClamp01(fullscreenFiniteNumber(condition, 100) / 100);
                    if (wear <= 0.001) return "rgba(0,0,0,0)";
                    if (wear < 0.25) return fullscreenMixColor([0, 0, 0], [70, 190, 255], wear / 0.25, wear * 1.5);
                    if (wear < 0.55) return fullscreenMixColor([70, 190, 255], [255, 210, 55], (wear - 0.25) / 0.30, 0.42 + wear * 0.25);
                    if (wear < 0.80) return fullscreenMixColor([255, 210, 55], [255, 125, 35], (wear - 0.55) / 0.25, 0.58 + wear * 0.20);
                    return fullscreenMixColor([255, 125, 35], [255, 48, 38], (wear - 0.80) / 0.20, 0.78);
                }

                function normalizeFullscreenWheelName(name) {
                    name = String(name || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
                    if (name === "FL" || name === "LF" || name.indexOf("FRONTLEFT") >= 0 || name.indexOf("LEFTFRONT") >= 0 || name.indexOf("FRONTL") >= 0 || /FL$/.test(name)) return "FL";
                    if (name === "FR" || name === "RF" || name.indexOf("FRONTRIGHT") >= 0 || name.indexOf("RIGHTFRONT") >= 0 || name.indexOf("FRONTR") >= 0 || /FR$/.test(name)) return "FR";
                    if (name === "RL" || name === "LR" || name.indexOf("REARLEFT") >= 0 || name.indexOf("LEFTREAR") >= 0 || name.indexOf("REARL") >= 0 || /RL$/.test(name)) return "RL";
                    if (name === "RR" || name.indexOf("REARRIGHT") >= 0 || name.indexOf("RIGHTREAR") >= 0 || name.indexOf("REARR") >= 0 || /RR$/.test(name)) return "RR";
                    return "";
                }

                function orderWheelDataForVehicleView(wheelData) {
                    wheelData = wheelData || [];
                    var byName = { FL: null, FR: null, RL: null, RR: null };
                    var extras = [];
                    wheelData.forEach(function (entry) {
                        var canonical = normalizeFullscreenWheelName(entry && entry.name);
                        if (canonical && !byName[canonical]) byName[canonical] = entry;
                        else if (entry) extras.push(entry);
                    });
                    var ordered = [];
                    ["FL", "FR", "RL", "RR"].forEach(function (name) {
                        if (byName[name]) ordered.push(byName[name]);
                    });
                    extras.forEach(function (entry) { ordered.push(entry); });
                    return ordered;
                }

                function syncVehicleDebugTelemetry(enabled) {
                    enabled = enabled === true;
                    try {
                        bngApi.activeObjectLua(
                            "if extensions.luukstyrethermalsandwear and extensions.luukstyrethermalsandwear.setHudDebugTelemetryEnabled then " +
                            "extensions.luukstyrethermalsandwear.setHudDebugTelemetryEnabled(" + (enabled ? "true" : "false") + ") end"
                        );
                    } catch (e) {}
                }

                function updateFullscreenDebugWheel(slot, wheelData, fallbackWheelName) {
                    if (!slot || !wheelData) return;
                    var wheelName = normalizeFullscreenWheelName(wheelData.name) || fallbackWheelName;
                    var dirtMode = wheelData.rally_dirt_model_active === true;
                    var groups = dirtMode ? fullscreenDirtGroups : fullscreenRoadGroups;
                    setFullscreenDebugRows(slot, groups, dirtMode ? "dirt" : "road");

                    var profileLabel = String(wheelData.tyre_profile_label || wheelData.tyre_profile || "Unknown tyre profile");
                    var compound = String(wheelData.rally_compound || wheelData.slick_compound || "");
                    var surface = dirtMode
                        ? String(wheelData.rally_surface_label || wheelData.rally_surface_class || "Dirt")
                        : String(wheelData.contact_material || "Hard road");
                    slot.tyreName.textContent = wheelName;
                    slot.title.textContent = wheelName + " — " + profileLabel;
                    slot.subtitle.textContent = surface + (compound ? "  ·  " + compound.toUpperCase() : "") +
                        "  ·  " + String(wheelData.tyre_name || "Unknown tyre");

                    var condition = fullscreenFiniteNumber(wheelData.condition, 0);
                    slot.tyreCondition.textContent = Math.max(0, Math.min(100, Math.round(condition))) + "%";
                    slot.tyreHead.style.backgroundColor = fullscreenConditionColor(condition);
                    slot.pressure.textContent = fullscreenFormat(wheelData.tyre_pressure_psi, 1, " PSI");

                    var workingTemperature = fullscreenFiniteNumber(wheelData.working_temp, 70);
                    var surfaceTemps = wheelData.surface_temp && wheelData.surface_temp.length >= 3
                        ? wheelData.surface_temp : wheelData.temp;
                    surfaceTemps = surfaceTemps && surfaceTemps.length >= 3 ? surfaceTemps : [workingTemperature, workingTemperature, workingTemperature];
                    var nominalDepth = fullscreenFiniteNumber(wheelData.tread_nominal_depth_mm, 0);
                    var meanRemaining = fullscreenFiniteNumber(wheelData.tread_remaining_depth_mm, nominalDepth);
                    var bulkTemperature = fullscreenFirstFinite([wheelData.bulk_tread_avg_temp, wheelData.avg_temp], workingTemperature);
                    var coreTemperature = fullscreenFirstFinite([
                        wheelData.core_temp,
                        wheelData.temp && wheelData.temp.length > 3 ? wheelData.temp[3] : NaN
                    ], bulkTemperature);
                    var remainingDepths = [
                        fullscreenFiniteNumber(wheelData.tread_remaining_outer_mm, meanRemaining),
                        fullscreenFiniteNumber(wheelData.tread_remaining_middle_mm, meanRemaining),
                        fullscreenFiniteNumber(wheelData.tread_remaining_inner_mm, meanRemaining)
                    ];
                    var treadFields = [wheelData.tread_field_outer, wheelData.tread_field_middle, wheelData.tread_field_inner];
                    for (var stripIndex = 0; stripIndex < 3; stripIndex++) {
                        var depthScale = nominalDepth > 0
                            ? fullscreenClamp01(remainingDepths[stripIndex] / nominalDepth)
                            : fullscreenClamp01(condition / 100);
                        slot.strips[stripIndex].style.height = Math.max(4, depthScale * 100).toFixed(1) + "%";
                        slot.strips[stripIndex].style.backgroundColor = "rgba(0,0,0,0)";
                        slot.strips[stripIndex].style.backgroundImage = "none";
                        var field = treadFields[stripIndex];
                        var layers = slot.stripLayers[stripIndex];
                        for (var layerIndex = 0; layerIndex < layers.length; layerIndex++) {
                            var depthFraction = layers.length > 1 ? layerIndex / (layers.length - 1) : 1;
                            var layerTemperature;
                            if (field && field.length) {
                                var sourceIndex = Math.round((1 - depthFraction) * (field.length - 1));
                                layerTemperature = fullscreenFiniteNumber(field[sourceIndex], bulkTemperature);
                            } else if (depthFraction < 0.55) {
                                layerTemperature = coreTemperature + (bulkTemperature - coreTemperature) * (depthFraction / 0.55);
                            } else {
                                layerTemperature = bulkTemperature +
                                    (fullscreenFiniteNumber(surfaceTemps[stripIndex], bulkTemperature) - bulkTemperature) *
                                    ((depthFraction - 0.55) / 0.45);
                            }
                            layers[layerIndex].style.backgroundColor = fullscreenTemperatureColor(
                                layerTemperature,
                                workingTemperature
                            );
                        }
                    }
                    slot.tyre.style.borderColor = fullscreenTemperatureColor(
                        fullscreenFirstFinite([wheelData.flash_temp, wheelData.physical_surface_temp_c, wheelData.surface_avg_temp], workingTemperature),
                        workingTemperature);

                    groups.forEach(function (group) {
                        group.rows.forEach(function (definition) {
                            var valueElement = slot.rows[definition.key];
                            if (valueElement) valueElement.textContent = definition.value(wheelData);
                        });
                    });
                }

                function fullscreenFirstFinite(values, fallback) {
                    for (var i = 0; i < values.length; i++) {
                        var value = Number(values[i]);
                        if (isFinite(value)) return value;
                    }
                    return fallback;
                }

                function clearFullscreenDebugWheel(slot, wheelName) {
                    if (!slot) return;
                    slot.tyreName.textContent = wheelName;
                    slot.tyreCondition.textContent = "—%";
                    slot.pressure.textContent = "— PSI";
                    slot.title.textContent = wheelName + " — no wheel data";
                    slot.subtitle.textContent = "Waiting for live wheel telemetry";
                    slot.tyre.style.borderColor = "rgba(180,225,245,.62)";
                    slot.tyreHead.style.backgroundColor = "rgba(0,0,0,0)";
                    for (var i = 0; i < slot.strips.length; i++) {
                        slot.strips[i].style.height = "100%";
                        slot.strips[i].style.backgroundColor = "rgba(90,180,220,.20)";
                        slot.strips[i].style.backgroundImage = "none";
                        for (var layerIndex = 0; layerIndex < slot.stripLayers[i].length; layerIndex++) {
                            slot.stripLayers[i][layerIndex].style.backgroundColor = "rgba(90,180,220,.20)";
                        }
                    }
                    Object.keys(slot.rows).forEach(function (key) {
                        slot.rows[key].textContent = "—";
                    });
                }

                function updateFullscreenDebug(wheelData) {
                    fullscreenDebugLatestWheelData = wheelData || [];
                    if (!fullscreenDebugOpen) return;
                    var byName = {};
                    var unnamed = [];
                    fullscreenDebugLatestWheelData.forEach(function (entry) {
                        var normalized = normalizeFullscreenWheelName(entry && entry.name);
                        if (normalized && !byName[normalized]) byName[normalized] = entry;
                        else if (entry) unnamed.push(entry);
                    });
                    var orderedNames = ["FL", "FR", "RL", "RR"];
                    orderedNames.forEach(function (wheelName) {
                        var wheelDataEntry = byName[wheelName] || unnamed.shift();
                        if (wheelDataEntry) updateFullscreenDebugWheel(
                            fullscreenDebugWheelSlots[wheelName], wheelDataEntry, wheelName);
                        else clearFullscreenDebugWheel(fullscreenDebugWheelSlots[wheelName], wheelName);
                    });
                }

                function setFullscreenDebugOpen(open) {
                    open = open === true && debugTempsEnabled === true;
                    fullscreenDebugOpen = open;
                    fullscreenDebugOverlay.hidden = !open;
                    if (open) root.classList.add("fullscreen-debug-active");
                    else root.classList.remove("fullscreen-debug-active");
                    if (open) {
                        setPanelOpen(false);
                        updateFullscreenDebug(fullscreenDebugLatestWheelData);
                    }
                }

                var profilePresetBoundKeys = {
                    structure_side_spring_scale: true,
                    structure_reinf_spring_scale: true,
                    tread_grip_depth_mm: true,
                    tread_rubber_conductivity: true,
                    tread_rubber_density: true,
                    tread_rubber_cp: true,
                    profile_tread_depth_mm: true,
                    profile_rolling_resistance: true,
                    profile_tread_core_conductance: true,
                    profile_slip_heat_partition: true,
                    profile_deformation_scale: true,
                    profile_core_capacity_scale: true,
                    profile_tread_void_ratio: true,
                    ground_cooling_strength_percent: true,
                    grass_ground_cooling_strength_percent: true,
                    grass_slip_heat_rate: true,
                    water_cooling_multiplier: true,
                    contact_patch_log_gain: true,
                    contact_patch_deadzone_percent: true,
                    ground_cooling_max_factor: true,
                    cool_slide_floor_standard: true,
                    cool_slide_floor_sport: true,
                    cool_slide_floor_race: true,
                    cool_slide_floor_rally_asphalt: true,
                    cool_slide_floor_rally_gravel: true,
                    cool_slide_floor_drift: true
                };

                var profilePresetAutoReadOnly = false;

                function updateProfilePresetReadOnly(readOnly) {
                    profilePresetAutoReadOnly = readOnly === true;
                    Object.keys(profilePresetBoundKeys).forEach(function (key) {
                        var input = tuningInputs[key];
                        var reset = tuningResetButtons[key];
                        if (input) {
                            input.disabled = profilePresetAutoReadOnly;
                            input.title = profilePresetAutoReadOnly
                                ? "Detected preset owns this value. The actual effective/representative numeric solver value is shown read-only. If different wheel classes are fitted, the Advanced panel shows the representative detected profile while the tyre profile card remains per-wheel."
                                : "Manual preset active: this edits the actual solver value directly.";
                            input.classList.remove("invalid");
                        }
                        if (reset) reset.disabled = profilePresetAutoReadOnly;
                        var row = tuningRows[key];
                        if (row) row.classList.toggle("auto-readonly", profilePresetAutoReadOnly);
                    });
                }

                var liveTreadOwnedKeys = {
                    structure_tread_spring_scale: true,
                    structure_tread_damp_scale: true,
                    structure_tread_precompression_scale: true
                };

                function getTuningDefinitionByKey(key) {
                    var found = null;
                    tuningGroups.some(function (group) {
                        return group.settings.some(function (definition) {
                            if (definition.key === key) { found = definition; return true; }
                            return false;
                        });
                    });
                    return found;
                }

                function getLiveTreadAverage(dataStream, wheelField, fallbackValue) {
                    var rows = dataStream && dataStream.data ? dataStream.data : [];
                    var sum = 0;
                    var count = 0;
                    for (var i = 0; i < rows.length; i++) {
                        var row = rows[i];
                        if (!row || row.sport_physical_stiffness_active !== true) continue;
                        var value = Number(row[wheelField]);
                        if (!isFinite(value)) continue;
                        sum += value;
                        count += 1;
                    }
                    return count > 0 ? sum / count : Number(fallbackValue);
                }

                function updateLiveTreadPhysicalReadOnly(enabled, dataStream) {
                    var readOnly = enabled === true;
                    var fieldMap = {
                        structure_tread_spring_scale: "sport_stiffness_applied_tread_scale",
                        structure_tread_damp_scale: "sport_stiffness_tread_damp_scale",
                        structure_tread_precompression_scale: "sport_stiffness_applied_precomp_scale"
                    };
                    Object.keys(liveTreadOwnedKeys).forEach(function (key) {
                        var input = tuningInputs[key];
                        var reset = tuningResetButtons[key];
                        var row = tuningRows[key];
                        if (!input) return;

                        input.disabled = readOnly;
                        if (reset) reset.disabled = readOnly;
                        if (row) row.classList.toggle("live-tread-readonly", readOnly);

                        if (readOnly) {
                            var definition = getTuningDefinitionByKey(key);
                            var manualValue = currentTuningValues[key];
                            if (!isFinite(Number(manualValue))) manualValue = definition ? definition.defaultValue : 1;
                            var liveValue = getLiveTreadAverage(dataStream, fieldMap[key], manualValue);
                            if (!isFinite(liveValue)) liveValue = Number(manualValue);
                            var liveDisplayValue = Number(formatTuningValue(definition, liveValue));
                            var baseDisplayMax = Number(definition && definition.displayMax !== undefined ? definition.displayMax : 200);
                            if (isFinite(liveDisplayValue) && liveDisplayValue > baseDisplayMax) {
                                input.max = String(Math.ceil(liveDisplayValue / 25) * 25);
                            } else {
                                input.max = String(baseDisplayMax);
                            }
                            input.value = String(liveDisplayValue);
                            if (input._valueLabel) input._valueLabel.textContent = formatNumber(liveDisplayValue) + "%";
                            input.title = "LIVE / LOCKED: KTS currently owns this tread structural parameter. Display is the average actual applied value across active live-stiffness wheels. Untick Live tread physical stiffness to restore manual editing.";
                            if (row) row.title = input.title;
                        } else {
                            var unlockedDefinition = getTuningDefinitionByKey(key);
                            if (unlockedDefinition && unlockedDefinition.type === "range") {
                                input.max = String(unlockedDefinition.displayMax === undefined ? 200 : unlockedDefinition.displayMax);
                            }
                            var storedValue = currentTuningValues[key];
                            if (!isFinite(Number(storedValue))) storedValue = unlockedDefinition ? unlockedDefinition.defaultValue : 1;
                            input.value = formatTuningValue(unlockedDefinition, storedValue);
                            if (input._valueLabel) input._valueLabel.textContent = input.value + "%";
                            input.title = unlockedDefinition ? tuningDisplayHelp(unlockedDefinition) : "";
                            if (row && unlockedDefinition) row.title = tuningDisplayHelp(unlockedDefinition);
                        }
                    });
                }

                var tuningGroups = [
                    {
                        title: "TRAFFIC SIMULATION (EXPERIMENTAL)",
                        settings: [
                            { key: "experimental_enable_all_spawned_cars", label: "Enable in all spawned cars", type: "checkbox", defaultValue: 0, min: 0, max: 1, statusOn: "Full KTS simulation enabled on all spawned vehicles", statusOff: "Continuous KTS runs on player vehicle only", help: "Performance option. Unchecked (default): every spawned vehicle still initializes KTS and keeps its local tyre state, but updateGFX/updatePhysics continuous tyre calculations run only while that vehicle is the currently seated player vehicle. This makes traffic/AI much cheaper and Tab switching resumes KTS on the selected vehicle. Checked: all spawned vehicles continuously simulate KTS, intended for users with spare CPU headroom." }
                        ]
                    },
                    {
                        title: "SPORT PHYSICAL STIFFNESS",
                        settings: [
                            { key: "sport_physical_stiffness_enabled", label: "Live tread physical stiffness", type: "checkbox", defaultValue: 1, min: 0, max: 1, statusOn: "Live tread physical stiffness enabled", statusOff: "Live tread physical stiffness disabled", help: "KTS owns the temperature-driven tread-beam spring, stability damping and automatic tread precompression for supported physical-stiffness tyre families. While enabled, those three structure sliders are locked and display their actual live applied vehicle-average values instead of dormant manual calibration multipliers." },
                            { key: "sport_stiffness_warm_target_strength", label: "Temperature-stiffness curve strength", type: "range", defaultValue: 1.00, min: 0, max: 1.25, displayMin: 0, displayMax: 125, displayStep: 1, help: "Scales the complete Sport structural-temperature deviation around BeamNG native. 100% = current research curve; 0% = native BeamNG structure at every temperature; 125% = diagnostic exaggeration. Aspect ratio no longer scales this temperature sensitivity." }
                        ]
                    },
                    {
                        title: "TYRE CONSTRUCTION JBEAM (EXPERIMENTAL)",
                        settings: [
                            { key: "experimental_blacklist_current_tyre_id", label: "Blacklist current tyre ID", type: "checkbox", defaultValue: 0, min: 0, max: 1, statusOn: "Current race tyre ID is blacklisted", statusOff: "Current race tyre ID is not blacklisted", help: "Race tyres only. Checked: save the currently fitted race tyre ID(s) to the persistent live tread-stiffness blacklist and keep live tread physical stiffness disabled for those IDs. Unchecked: remove the currently fitted race tyre ID(s) from the blacklist, including IDs learned automatically after a startup pop. Unchecking does not automatically turn live stiffness back on; use the Live tread physical stiffness toggle when you want to re-enable it. Non-race tyre IDs are ignored." },
                            { key: "structure_side_spring_scale", label: "Sidewall base stiffness", type: "range", directPercent: true, defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "ACTUAL final class sidewall base stiffness relative to the tyre's original BeamNG side-beam spring. Presets show their literal values (Standard 80%, Sport 92%, Semi-slick 95%); this is not a hidden multiplier on top of the preset." },
                            { key: "structure_side_damp_scale", label: "Sidewall base damping", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC multiplier on generated side-beam base damping. 100% = original BeamNG value." },
                            { key: "structure_side_expansion_spring_scale", label: "Sidewall expansion stiffness", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC calibration-only multiplier on anisotropic side-beam EXPANSION spring. v1.5 physical temperature correction NEVER touches this parameter; keep it at 100% for Sport stiffness validation." },
                            { key: "structure_side_expansion_damp_scale", label: "Sidewall expansion damping", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC multiplier on anisotropic side-beam EXPANSION damping. 100% = original." },
                            { key: "structure_tread_spring_scale", label: "Tread-beam stiffness", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC multiplier on BeamNG's generated tread-beam spring group. 100% = original." },
                            { key: "structure_tread_damp_scale", label: "Tread-beam damping", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC multiplier on generated tread-beam damping. 100% = original." },
                            { key: "structure_tread_precompression_scale", label: "Tread precompression", type: "range", defaultValue: 1.00, min: 0.8, max: 1.2, displayMin: 80, displayMax: 120, displayStep: 0.1, help: "GEOMETRY CALIBRATION. Multiplies the tyre's native wheelTreadBeamPrecompression using BeamNG setBeamLengthRefRatio(). 100% preserves the original JBeam ratio (for this Bolide tyre, nominally 0.98). With reduced TreadSpring, move this until WIDTH Δ returns near 0.00%. Lower ratio generally pulls the across-tread structure inward more strongly. Test while stationary first." },
                            { key: "structure_side_precompression_scale", label: "Sidewall precompression", type: "range", defaultValue: 1.00, min: 0.8, max: 1.2, displayMin: 80, displayMax: 120, displayStep: 0.1, help: "EXPERIMENTAL. Multiplies native wheelSideBeamPrecompression. Use only after the tread-precompression test; it can alter carcass/radial equilibrium." },
                            { key: "structure_reinf_precompression_scale", label: "Reinforcement precompression", type: "range", defaultValue: 1.00, min: 0.8, max: 1.2, displayMin: 80, displayMax: 120, displayStep: 0.1, help: "EXPERIMENTAL. Multiplies native wheelReinfBeamPrecompression / L-beam reference ratio. Keep at 100% during the first width-compensation sweep." },
                            { key: "structure_reinf_spring_scale", label: "Reinforcement stiffness", type: "range", directPercent: true, defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "ACTUAL final class reinforcement stiffness relative to the tyre's original BeamNG reinforcement beams. Presets show their literal values (Standard 89%, Sport 95%, Semi-slick 100%); this is not a hidden multiplier on top of the preset." },
                            { key: "structure_reinf_damp_scale", label: "Reinforcement damping", type: "range", defaultValue: 1.00, min: 0, max: 2, displayMin: 0, displayMax: 200, displayStep: 1, help: "STATIC multiplier on the generated tyre reinforcement-beam damping group. 100% = original." }
                        ]
                    },
                    {
                        title: "ROAD CONTACT COOLING",
                        settings: [
                            { key: "ground_cooling_strength_percent", label: "Hard-ground cooling", directPercent: true, defaultValue: 1, min: 0.01, max: 10, step: "0.01", help: "ACTUAL effective hard-ground road-boundary multiplier. 100% = 1.00x; no percent-of-preset normalization." },
                            { key: "grass_ground_cooling_strength_percent", label: "Grass cooling", directPercent: true, defaultValue: 10, min: 0.01, max: 50, step: "0.01", help: "ACTUAL effective grass road-boundary multiplier. General preset = 1000% / 10x asphalt; Race preset = 500% / 5x asphalt." },
                            { key: "grass_slip_heat_rate", label: "Grass slip heat", directPercent: true, defaultValue: 0.1666666666666667, min: 0, max: 16.6666666666667, step: "0.01", help: "ACTUAL effective grass slip-heat factor. 16.667% = 1/6 of the normal road slip-heat rate." },
                            { key: "water_cooling_multiplier", label: "Water cooling multiplier", directPercent: true, defaultValue: 30, min: 0, max: 1000, step: "0.1", help: "ACTUAL effective water-cooling multiplier. 3000% = 30x. Applied once to the wet tread air/road boundary; the current thermal network has no direct core-to-ambient cooling path." },
                            { key: "contact_patch_log_gain", label: "Light-contact cooling log gain", physicalValue: true, defaultValue: 100000, min: 0.000001, max: 1000000000, step: "any", help: "ACTUAL dimensionless logarithmic contact-shape gain used by the formula. This is not physically a percentage, so it is shown raw instead of inventing a normalized 100% value." },
                            { key: "contact_patch_deadzone_percent", label: "Minimum contact threshold", physicalValue: true, valueUnitLabel: "%", defaultValue: 0.2, min: 0, max: 50, step: "0.01", help: "ACTUAL nominal contact-patch percentage ignored as tiny load/contact noise. The UI value is already percent: 0.2 means 0.2%, and Vehicle Lua converts it once to the 0.002 ratio used by the formula." },
                            { key: "ground_cooling_max_factor", label: "Maximum contact cooling boost", directPercent: true, defaultValue: 1.35, min: 0, max: 10, step: "0.01", help: "ACTUAL upper contact-cooling multiplier. 135% = 1.35x maximum cooling under the load/pressure contact correction." }
                        ]
                    },
                    {
                        title: "Baseline grip uplift",
                        settings: [
                            { key: "baseline_grip_uplift_enabled", label: "Auto baseline grip uplift", type: "checkbox", defaultValue: 1, min: 0, max: 1, statusOn: "Detected tyre/profile uplift enabled", statusOff: "Baseline uplift disabled", help: "Absolute grip correction layer. It is applied separately from temperature/wear, brush breakaway and flash heat. Auto mode uses the actual detected tyre profile per wheel; exact tyre-part overrides can be added as calibration data is collected." },
                            { key: "baseline_uplift_standard", label: "Standard / road baseline grip", directPercent: true, defaultValue: 0.98, min: 0.70, max: 1.35, step: "0.5", help: "ACTUAL final baseline grip multiplier for Standard/road tyres. Current default is 98% of BeamNG native friction." },
                            { key: "baseline_uplift_sport", label: "Sport / performance-road baseline grip", directPercent: true, defaultValue: 1.01, min: 0.70, max: 1.35, step: "0.5", help: "ACTUAL final baseline grip multiplier for Sport/performance-road tyres. Current default is 101%." },
                            { key: "baseline_uplift_semi_slick", label: "Semi-slick / track-day baseline grip", directPercent: true, defaultValue: 1.02, min: 0.70, max: 1.35, step: "0.5", help: "ACTUAL final baseline grip multiplier for Semi-Slick/track-day tyres. Current default is 102%." },
                            { key: "baseline_uplift_race", label: "Race / slick uplift", directPercent: true, defaultValue: 1.00, min: 0.70, max: 1.35, step: "0.5", help: "ACTUAL hot/reference baseline multiplier for Race/slick tyres. Current default is 100%; a separate cold multiplier reduces the slick thermal curve by up to 10% when cold." },
                            { key: "baseline_uplift_rally_asphalt", label: "Rally Asphalt road uplift", directPercent: true, defaultValue: 1.00, min: 1.00, max: 1.10, step: "0.5", help: "ACTUAL hard-road Rally Asphalt peak multiplier used by the mutually-exclusive road route. 100% = 1.00x. Loose terrain does not receive this road multiplier." },
                            { key: "baseline_uplift_rally_gravel", label: "Rally Gravel road uplift", directPercent: true, defaultValue: 1.08, min: 1.00, max: 1.10, step: "0.5", help: "ACTUAL hard-road Rally Gravel peak multiplier. Current validated road-only calibration is 108% = 1.08x. Gravel/Dirt/Mud/Sand keep BeamNG native terrain grip and do NOT receive this road uplift." },
                            { key: "baseline_uplift_drift", label: "Drift uplift", directPercent: true, defaultValue: 1.00, min: 1.00, max: 1.35, step: "0.5", help: "ACTUAL final baseline grip multiplier for Drift tyres. 100% means no uplift; raise only if testing shows a specific drift tyre needs it." }
                        ]
                    },
                    {
                        title: "Preset Full-slide Target",
                        settings: [
                            { key: "cool_slide_floor_standard", label: "Standard / road target", directPercent: true, defaultValue: 0.86, min: 0.50, max: 1.20, step: "0.5", help: "ACTUAL whole-tyre fresh/cool full-slide mechanical target relative to the CURRENT temperature-limited peak. 86% means 0.86x current peak. Thermal loss then comes from the profile temperature curve; this is not percent-of-a-hidden preset." },
                            { key: "cool_slide_floor_sport", label: "Sport + semi-slick warm target", directPercent: true, defaultValue: 0.90, min: 0.50, max: 1.20, step: "0.5", help: "ACTUAL configured Sport/semi-slick warm full-slide anchor. 90% means 0.90x current peak at the warm anchor. The Sport temperature schedule may move the instantaneous cool-side ratio around this anchor; the number shown here is the literal solver anchor, not 100% of a hidden 0.90 value." },
                            { key: "cool_slide_floor_race", label: "Race / slick target", directPercent: true, defaultValue: 0.86, min: 0.50, max: 1.20, step: "0.5", help: "ACTUAL fresh/cool Race-slick full-slide mechanical target. 86% means 0.86x the current temperature-limited peak before longer thermal degradation." },
                            { key: "cool_slide_floor_rally_asphalt", label: "Rally Asphalt target", directPercent: true, defaultValue: 0.89, min: 0.50, max: 1.20, step: "0.5", help: "ACTUAL Rally Asphalt road-model full-slide mechanical target. 89% means 0.89x current peak on the model-owned hard-road route." },
                            { key: "cool_slide_floor_rally_gravel", label: "Rally Gravel target", directPercent: true, defaultValue: 0.84, min: 0.50, max: 1.20, step: "0.5", help: "ACTUAL Rally Gravel hard-road full-slide mechanical target. 84% means 0.84x current road peak. Native loose-terrain routing remains separate." },
                            { key: "cool_slide_floor_drift", label: "Drift target", directPercent: true, defaultValue: 0.00, min: 0.00, max: 1.20, step: "0.5", help: "Current Drift preset uses 0 as an explicit NATIVE sentinel: preserve the detected BeamNG mechanical endpoint instead of forcing a KTS full-slide target. Any non-zero value is literal (for example 90% = 0.90x current peak)." }
                        ]
                    },
                    {
                        title: "TYRE PRESET — ACTUAL PHYSICAL THERMAL VALUES",
                        settings: [
                            { key: "tread_grip_depth_mm", label: "Grip-temperature depth scale (mm)", physicalValue: true, defaultValue: 0.80, min: 0.10, max: 4.00, step: "0.05", help: "ACTUAL profile sampling depth used to derive the rubber temperature seen by the compound grip curve. Kept at 0.80 mm across current presets until research supports a class split." },
                            { key: "tread_rubber_conductivity", label: "Tread thermal conductivity k (W/mK)", physicalValue: true, defaultValue: 0.235, min: 0.05, max: 1.00, step: "0.005", help: "ACTUAL Fourier conductivity used by the active tyre profile. Manual preset: editable directly. Detected mode: greyed/read-only and shows the detected preset's real solver value." },
                            { key: "tread_rubber_density", label: "Tread rubber density (kg/m³)", physicalValue: true, defaultValue: 1125, min: 700, max: 1500, step: "5", help: "ACTUAL tread-rubber density used for thermal mass. Manual preset: editable directly. Detected mode: read-only actual detected preset value." },
                            { key: "tread_rubber_cp", label: "Tread specific heat cp (J/kgK)", physicalValue: true, defaultValue: 1590, min: 800, max: 3000, step: "10", help: "ACTUAL specific heat used by the tread solver. Research-guided family preset value, not a hidden multiplier." },
                            { key: "profile_tread_depth_mm", label: "Total tread rubber thickness (mm)", physicalValue: true, defaultValue: 9.5, min: 1.0, max: 20.0, step: "0.1", help: "ACTUAL total simulated rubber thickness above the core/belt boundary, including grooved cap, post-groove wearable rubber and the protected 0.5 mm numerical reserve. This is NOT the same thing as manufacturer-listed groove depth." },
                            { key: "profile_rolling_resistance", label: "Rolling resistance coefficient", physicalValue: true, defaultValue: 0.0120, min: 0.001, max: 0.050, step: "0.0005", help: "ACTUAL effective rolling-loss coefficient used directly by the hysteresis/rolling heat path. The old separate hysteresis wrapper has been merged into this value." },
                            { key: "profile_tread_core_conductance", label: "Tread ↔ core conductance (W/K)", physicalValue: true, defaultValue: 75, min: 1, max: 400, step: "1", help: "ACTUAL bulk-tread/carcass conductance for the selected tyre family." },
                            { key: "profile_slip_heat_partition", label: "Tyre-retained slip heat share", physicalValue: true, defaultValue: 0.30, min: 0, max: 1, step: "0.01", help: "ACTUAL fraction of local slip-loss power retained by the tyre thermal system. Retained gross-slip heat now enters the physical road-facing tread boundary directly." },
                            { key: "profile_deformation_scale", label: "Extra flex hysteresis scale", physicalValue: true, defaultValue: 1.00, min: 0.10, max: 3.00, step: "0.01", help: "ACTUAL profile multiplier on force-induced brush hysteresis ABOVE ordinary free rolling. Crr×Fz×v is the sole baseline rolling-flex budget; this control scales only the small additional Fx/Fy deformation loss while the brush is still adhering/deforming." },
                            { key: "profile_core_capacity_scale", label: "Core thermal-capacity scale", physicalValue: true, defaultValue: 1.00, min: 0.50, max: 2.00, step: "0.01", help: "ACTUAL profile multiplier on the derived carcass/core thermal capacity. 1.00 is neutral." },
                            { key: "profile_tread_void_ratio", label: "Fresh surface groove void ratio", physicalValue: true, defaultValue: 0.35, min: 0, max: 0.60, step: "0.01", help: "ACTUAL fresh road-facing groove/open area fraction. Uses a separate depth taper toward the groove floor; this value no longer removes the same fraction from every tread cell. Slick remains 0." }
                        ]
                    },
                    {
                        title: "12-cell tread diffusion / slip calibration",
                        settings: [
                            { key: "repeated_test_thermal_cap_enabled", label: "Repeated-test bulk thermal cap", type: "checkbox", defaultValue: 0, min: 0, max: 1, statusOn: "Repeated-test thermal cap ON", statusOff: "Full 12-cell heat memory", help: "Calibration aid only; unrelated to Arcade Tyre Mode. The first 3 road-side cells + microscopic FLASH stay uncapped. Deeper tread cells are capped at 120% of optimum and CORE/air at optimum, so repeated fast-slide tests can isolate transient tread behavior without slow heat-soak running away." },
                            { key: "surface_heat_memory_enabled", label: "Depth-resolved tread grip thermals", type: "checkbox", defaultValue: 1, min: 0, max: 1, statusOn: "12-cell tread grip thermals enabled", statusOff: "Tread field simulated; grip mapping disabled", help: "All 12 tread cells remain the structural/bulk thermal body. Direct compound grip is evaluated from road-side cells 1–3 as per-cell hot/cold grip losses before averaging, so cold and overheated cells cannot cancel into a fake working temperature. The road boundary/flash state remains a faster local thermal layer." },
                            { key: "cross_tread_research_enabled", label: "Pressure / structure tread-load model", type: "checkbox", defaultValue: 1, min: 0, max: 1, statusOn: "Research cross-tread model enabled", statusOff: "Legacy camber-only zone loading", help: "Research-backed reduced-order transverse pressure model. Low pressure/high load/compliant construction shifts load toward the shoulders; high pressure/stiff construction shifts it toward the centre. Lateral flex heat then gets a separate structure-dependent shoulder bias." },
                            { key: "cross_tread_pressure_shape_gain", label: "Shoulder/centre load sensitivity", defaultValue: 0.75, min: 0.00, max: 1.50, step: "0.01", help: "Maps the research deflection proxy into shoulder-vs-centre contact load. Default is bounded so severe underinflation approaches but does not exceed the 2:1 shoulder/centre calibration cap." },
                            { key: "cross_tread_pressure_exponent", label: "Pressure influence strength", defaultValue: 0.95, min: 0.00, max: 2.00, step: "0.01", help: "Strength of live pressure relative to the tyre's working-pressure reference in the transverse load profile. Research shows inflation acts particularly strongly on the centre region." },
                            { key: "cross_tread_load_exponent", label: "Load influence strength", defaultValue: 0.65, min: 0.00, max: 1.50, step: "0.01", help: "Strength of wheel load in the transverse pressure shape. SAE contact-pressure measurements found loading especially influences shoulder-region pressure." },
                            { key: "cross_tread_flex_edge_gain", label: "Shoulder heat from lateral flex", defaultValue: 0.65, min: 0.00, max: 2.00, step: "0.01", help: "Adds shoulder-biased viscoelastic heat from lateral carcass/tread deformation. It is driven by absolute lateral strain demand and actual pressure-wheel compliance, not by B100 alone." },
                            { key: "cross_tread_flex_compliance_exponent", label: "Flex sensitivity to tyre softness", defaultValue: 1.00, min: 0.00, max: 2.00, step: "0.01", help: "Controls how strongly tall/soft/low-pressure structures produce shoulder deformation heat compared with stiff low-profile tyres at the same rim slip." },
                            { key: "cross_tread_crown_support_sport", label: "Sport crown/belt support", defaultValue: 0.80, min: 0.00, max: 4.00, step: "0.05", help: "Parallel structural crown support for Sport/UHP/semi-slick tyres. It suppresses symmetric both-shoulder collapse from high vertical load and excessive lateral flex while leaving camber-induced inner/outer load shift at full authority. Native 0.80 = moderate crown support." },
                            { key: "cross_tread_crown_support_race", label: "Race slick crown/belt support", defaultValue: 2.00, min: 0.00, max: 5.00, step: "0.05", help: "Strong parallel belt/crown support for race slicks. High aero load mainly grows footprint load/length instead of forcing both shoulders to dominate. Camber asymmetry is not reduced. Native 2.00 = crown structural support approximately twice the normalized pneumatic support at the design point." },

                            { key: "flash_input_fraction", label: "Flash heat input share", defaultValue: 0.10, min: 0.01, max: 0.50, step: "0.01", help: "Fraction of local friction power used to excite the almost-massless microscopic flash state before its saturation/road losses." },
                            { key: "flash_to_surface_conductance", label: "Flash → tread conductance (W/K)", physicalValue: true, defaultValue: 4.0, min: 0.0, max: 25.0, step: "0.25", help: "Small microscopic heat path from FLASH into the physical road-side tread cells. Most flash temperature can disappear without storing its full temperature rise in the tyre." },
                            { key: "flash_retained_share", label: "Maximum flash heat retention", defaultValue: 0.20, min: 0.00, max: 0.75, step: "0.01", help: "Caps the fraction of already-retained tyre slip heat represented by the FLASH→tread path, preventing double-counting energy." }
                        ]
                    },
                    {
                        title: "Tread surface",
                        settings: [
                            { key: "locked_patch_flash_grip_enabled", label: "Microscopic flash-heat grip", type: "checkbox", defaultValue: 1, min: 0, max: 1, statusOn: "Flash thermal grip enabled", statusOff: "Flash thermal grip disabled", help: "Controls only the fastest millisecond asperity-flash layer. The new thin surface heat memory is a separate seconds-scale layer, so turning Flash off no longer disables the longer sliding-heat history." },
                            { key: "flash_micro_temp_sensitivity", label: "Flash-heat grip sensitivity", defaultValue: 0.15, min: 0, max: 2, step: "0.01", help: "Small FINAL microscopic friction correction. v13.4 feeds retained flash ENERGY into the physical surface separately, so this direct grip path is deliberately subtle: 0.15 means +100 C flash above the skin maps to only +15 C of hot-side equivalent grip loss." },
                            { key: "working_temp_c", label: "Working temp override (°C)", physicalValue: true, defaultValue: -1, min: -1, max: 250, step: "0.5", help: "AUTO uses each selected tyre profile working temperature. Enter a number to override all tyres; the profile grip curve shifts with it." },
                            { key: "hot_grip_loss_factor", label: "Overheat grip loss", defaultValue: 1, min: 0, max: 50, step: "0.1", help: "Scales the automatically selected profile's loss above its overheat threshold. 1 = profile default, 0 = no hot-side loss, 2 = double loss." },
                            { key: "slip_heat_rate", label: "Sliding heat generation", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Direct multiplier on the calibrated tyre-retained local slip-power branch. Native = 1.0." },
                            { key: "cornering_heat_rate", label: "Extra brush-flex heat", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Experimental multiplier on the small hysteretic fraction of force-induced Fx/Fy brush deformation. It does NOT multiply baseline Crr rolling heat. As true sliding grows, energy leaves this branch and moves into the road-facing surface/hotspot friction branch." },

                                { key: "ambient_skin_cooling_rate", label: "Low-speed tread air cooling", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Direct multiplier on calibrated low-speed surface convection. Native = 1.0." },
                            { key: "speed_skin_cooling_rate", label: "Speed-dependent tread air cooling", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Direct multiplier on calibrated speed-dependent surface convection. Native = 1.0." },
                        ]
                    },
                    {
                        title: "Tyre core",
                        settings: [
                            { key: "brake_to_core_rate", label: "Brake → rim heat transfer", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Direct multiplier on calibrated physical brake-disc → wheel/rim conductance. Heat then reaches cavity/bead/core through the wheel thermal network; there is no direct brake → tyre-core heater. Native = 1.0." }
                        ]
                    },
                    {
                        title: "Wear",
                        settings: [
                            { key: "wear_rate", label: "Tyre wear rate", defaultValue: 1, min: 0, max: 10, step: "0.01", help: "Direct multiplier on the calibrated v13.10.5+ abrasion model. Native = 1.0; normal pre-saturation motion stays mild while U>1 gross sliding still ramps strongly." }
                        ]
                    }
                ];

                function stopUiPropagation(event) {
                    event.stopPropagation();
                }

                [settingsButton, settingsPanel].forEach(function (node) {
                    node.addEventListener("mousedown", stopUiPropagation);
                    node.addEventListener("mouseup", stopUiPropagation);
                    node.addEventListener("click", stopUiPropagation);
                    node.addEventListener("wheel", stopUiPropagation);
                });

                function getBeamNgApi() {
                    try {
                        if (window.bngApi) return window.bngApi;
                    } catch (ignored) {}
                    try {
                        if (typeof bngApi !== "undefined") return bngApi;
                    } catch (ignoredAgain) {}
                    try {
                        var injector = window.angular && window.angular.element(document.body).injector();
                        if (injector) return injector.get("bngApi");
                    } catch (ignoredInjector) {}
                    return null;
                }

                function refocusInput(input) {
                    if (!input) return;
                    [0, 40, 140].forEach(function (delay) {
                        window.setTimeout(function () {
                            if (settingsPanel.hidden || !document.body.contains(input)) return;
                            try { window.focus(); } catch (ignored) {}
                            try {
                                input.focus({ preventScroll: true });
                            } catch (error) {
                                input.focus();
                            }
                        }, delay);
                    });
                }

                function setKeyboardCapture(capture, input) {
                    capture = !!capture;
                    cefKeyboardCaptured = capture;
                    if (keyboardCaptureTimer) {
                        window.clearInterval(keyboardCaptureTimer);
                        keyboardCaptureTimer = null;
                    }
                    if (capture) {
                        refocusInput(input || activeTuningInput);
                    }
                }

                function setStatus(message) {
                    settingsStatus.textContent = message;
                }

                function formatNumber(value) {
                    var number = Number(value);
                    if (!isFinite(number)) return "";
                    var abs = Math.abs(number);
                    if ((abs > 0 && abs < 0.0001) || abs >= 10000000) {
                        return number.toExponential(6).replace(/\.0+e/, "e");
                    }
                    return String(Number(number.toPrecision(9)));
                }

                function getNativeTuningValue(definition) {
                    if (!definition) return NaN;
                    var streamed = Number(nativeTuningValues[definition.key]);
                    if (isFinite(streamed)) return streamed;
                    return Number(definition.defaultValue);
                }

                function usesDirectPercent(definition) {
                    return !!(definition && definition.directPercent === true);
                }

                function usesNativePercent(definition) {
                    if (!definition || usesDirectPercent(definition) || definition.type === "checkbox" || definition.physicalValue === true || definition.key === "working_temp_c") return false;
                    var nativeValue = getNativeTuningValue(definition);
                    return isFinite(nativeValue) && nativeValue > 0;
                }

                function rawToNativePercent(definition, rawValue) {
                    if (usesDirectPercent(definition)) return Number(rawValue) * 100;
                    var nativeValue = getNativeTuningValue(definition);
                    if (!usesNativePercent(definition)) return Number(rawValue);
                    return Number(rawValue) / nativeValue * 100;
                }

                function nativePercentToRaw(definition, percentValue) {
                    if (usesDirectPercent(definition)) return Number(percentValue) / 100;
                    var nativeValue = getNativeTuningValue(definition);
                    if (!usesNativePercent(definition)) return Number(percentValue);
                    return nativeValue * Number(percentValue) / 100;
                }

                function tuningDisplayLabel(definition) {
                    if (!definition) return "";
                    return definition.label;
                }

                function tuningDisplayHelp(definition) {
                    if (!definition) return "";
                    var help = definition.help || "";
                    if (usesDirectPercent(definition)) {
                        help += (help ? " " : "") + "Displayed percentage is the ACTUAL effective multiplier: 100% = 1.00x; it is not normalized to a hidden preset baseline.";
                    } else if (usesNativePercent(definition)) {
                        var nativeValue = getNativeTuningValue(definition);
                        help += (help ? " " : "") + "100% = current native/calibrated value " + formatNumber(nativeValue) + ".";
                    } else if (definition && definition.physicalValue === true) {
                        help += (help ? " " : "") + "This field is shown directly in its physical/native unit, not as % of native.";
                    } else if (definition.type !== "checkbox" && definition.key !== "working_temp_c") {
                        help += (help ? " " : "") + "This control has a zero/non-positive native baseline, so multiplicative % normalization is undefined and the raw value is shown.";
                    }
                    return help;
                }

                function formatTuningValue(definition, value) {
                    var number = Number(value);
                    if (definition && definition.key === "working_temp_c" && isFinite(number) && number < 0) {
                        return "AUTO";
                    }
                    if (usesDirectPercent(definition) || usesNativePercent(definition)) {
                        return formatNumber(rawToNativePercent(definition, value));
                    }
                    return formatNumber(value);
                }

                function updateTuningNativeValues(values) {
                    if (!values) return;
                    Object.keys(values).forEach(function (key) {
                        var value = Number(values[key]);
                        if (isFinite(value)) nativeTuningValues[key] = value;
                    });

                    tuningGroups.forEach(function (group) {
                        group.settings.forEach(function (definition) {
                            var label = tuningLabels[definition.key];
                            var row = tuningRows[definition.key];
                            if (label) label.textContent = tuningDisplayLabel(definition);
                            if (row) row.title = tuningDisplayHelp(definition);
                            var input = tuningInputs[definition.key];
                            if (input) input.setAttribute("aria-label", tuningDisplayLabel(definition));
                        });
                    });
                }

                function queueVehicleCommand(vehicleCommand) {
                    var api = getBeamNgApi();
                    if (!api || typeof api.engineLua !== "function") {
                        setStatus("BeamNG UI bridge unavailable");
                        return false;
                    }
                    try {
                        api.engineLua(
                            "local vehicle = be:getPlayerVehicle(0); " +
                            "if vehicle then vehicle:queueLuaCommand(" + JSON.stringify(vehicleCommand) + ") end"
                        );
                        return true;
                    } catch (error) {
                        setStatus("Could not send command to vehicle");
                        return false;
                    }
                }

                function sendWearToggle() {
                    queueVehicleCommand("extensions.luukstyrethermalsandwear.toggleTyreWear()");
                }

                function sendThermalPause(paused) {
                    queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setThermalSimulationPaused(" + (paused ? "true" : "false") + ")"
                    );
                }

                function handleWearButtonClick() {
                    if (wearClickTimer !== null) {
                        clearTimeout(wearClickTimer);
                        wearClickTimer = null;
                        thermalsPaused = true;
                        sendThermalPause(true);
                        return;
                    }

                    wearClickTimer = setTimeout(function () {
                        wearClickTimer = null;
                        if (thermalsPaused) {
                            thermalsPaused = false;
                            sendThermalPause(false);
                        } else {
                            wearEnabled = !wearEnabled;
                            sendWearToggle();
                        }
                    }, wearClickWindowMs);
                }

                function sendTuningValue(key, value) {
                    queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setTuningValue(" + JSON.stringify(key) + "," + Number(value) + ")"
                    );
                }

                function sendArcadeHandlingMode(enabled) {
                    var boolText = enabled ? "true" : "false";
                    var numericText = enabled ? "1" : "0";
                    return queueVehicleCommand(
                        "local e=extensions.luukstyrethermalsandwear; " +
                        "if e then " +
                        "if e.setArcadeHandlingMode then e.setArcadeHandlingMode(" + boolText + ") " +
                        "elseif e.setTuningValue then e.setTuningValue('arcade_handling_mode_enabled'," + numericText + ") " +
                        "end end"
                    );
                }

                function clearArcadeHandlingAckTimer() {
                    if (arcadeHandlingAckTimer !== null) {
                        window.clearTimeout(arcadeHandlingAckTimer);
                        arcadeHandlingAckTimer = null;
                    }
                }

                function armArcadeHandlingAck(expectedState, startingRevision) {
                    clearArcadeHandlingAckTimer();
                    arcadeHandlingPendingState = expectedState === true;
                    arcadeHandlingPendingRevision = Number(startingRevision);
                    arcadeHandlingAckTimer = window.setTimeout(function () {
                        arcadeHandlingAckTimer = null;
                        if (arcadeHandlingRevision <= arcadeHandlingPendingRevision) {
                            queueVehicleCommand(
                                "extensions.luukstyrethermalsandwear.setTuningValue(" +
                                JSON.stringify("arcade_handling_mode_enabled") + "," +
                                (arcadeHandlingPendingState ? "1" : "0") + ")"
                            );
                            setStatus("Mode press received — waiting for vehicle ACK…");
                            arcadeHandlingAckTimer = window.setTimeout(function () {
                                arcadeHandlingAckTimer = null;
                                if (arcadeHandlingRevision <= arcadeHandlingPendingRevision) {
                                    arcadeHandlingButton.classList.add("mode-error");
                                    setStatus("Tyre mode command not ACKed by vehicle Lua");
                                }
                            }, 450);
                        }
                    }, 220);
                }

                function triggerArcadeHandlingToggle(event) {
                    var now = Date.now();
                    if (now - arcadeHandlingLastPressMs < 180) {
                        if (event) {
                            event.preventDefault();
                            event.stopPropagation();
                        }
                        return;
                    }
                    arcadeHandlingLastPressMs = now;

                    var next = !arcadeHandlingEnabled;
                    var startingRevision = arcadeHandlingRevision;
                    if (arcadeHandlingButton) arcadeHandlingButton.classList.remove("mode-error");

                    updateArcadeHandlingButton(next);
                    setStatus(next
                        ? "Mode press received → ARCADE"
                        : "Mode press received → REALISTIC");

                    if (!sendArcadeHandlingMode(next)) {
                        updateArcadeHandlingButton(!next);
                        setStatus("Could not send tyre mode command");
                    } else {
                        armArcadeHandlingAck(next, startingRevision);
                    }

                    if (event) {
                        event.preventDefault();
                        event.stopPropagation();
                    }
                }

                function updateArcadeHandlingButton(enabled) {
                    enabled = enabled === true;
                    arcadeHandlingEnabled = enabled;
                    currentTuningValues.arcade_handling_mode_enabled = enabled ? 1 : 0;
                    if (!arcadeHandlingButton) return;
                    arcadeHandlingButton.classList.toggle("active", enabled);
                    arcadeHandlingButton.setAttribute("aria-pressed", enabled ? "true" : "false");
                    arcadeHandlingButton.innerHTML = enabled
                        ? '<span class="mode-main">⚡ ARCADE TYRE MODE</span><span class="mode-sub">v2.0 · realistic baseline · 60% thermal penalties</span>'
                        : '<span class="mode-main">◇ REALISTIC TYRE MODE</span><span class="mode-sub">v2.0 · full thermal + stiffness severity</span>';
                    arcadeHandlingButton.title = enabled
                        ? "Arcade 2.0: same dynamic B100, load/pressure/geometry, baseline grip and post-peak model as Realistic. Temperature grip penalties are reduced to 60% severity; thermal stiffness deviations are reduced to 60%, with Sport physical stiffness converging to the Realistic warm target near working state."
                        : "Realistic tyre mode ON: full per-wheel dynamic B100, structural temperature, pressure/load geometry, model-owned post-peak envelope and full thermal/stiffness severity.";
                }

                function sendResetValue(key) {
                    queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.resetTuningValue(" + JSON.stringify(key) + ")"
                    );
                }

                function sendResetAll() {
                    queueVehicleCommand("extensions.luukstyrethermalsandwear.resetAllTuningValues()");
                }

                function sendTyreProfilePreset(profileId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setTyreProfilePreset(" + JSON.stringify(profileId) + ")"
                    );
                }

                function sendSlickCompoundPreset(compoundId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setSlickCompoundPreset(" + JSON.stringify(compoundId) + ")"
                    );
                }

                function sendRallySurfacePreset(surfaceId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setRallySurfacePreset(" + JSON.stringify(surfaceId) + ")"
                    );
                }

                function sendRallyCompoundPreset(compoundId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setRallyCompoundPreset(" + JSON.stringify(compoundId) + ")"
                    );
                }

                function sendRacingPitMode(enabled) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setRacingPitMode(" + (enabled ? "true" : "false") + ")"
                    );
                }

                function sendStagePitTyreProfile(profileId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitTyreProfile(" + JSON.stringify(profileId) + ")"
                    );
                }

                function sendStagePitSlickCompound(compoundId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitSlickCompound(" + JSON.stringify(compoundId) + ")"
                    );
                }

                function sendStagePitRallySurface(surfaceId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitRallySurface(" + JSON.stringify(surfaceId) + ")"
                    );
                }

                function sendStagePitRallyCompound(compoundId) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitRallyCompound(" + JSON.stringify(compoundId) + ")"
                    );
                }

                function sendPitStopRequest() {
                    return queueVehicleCommand("extensions.luukstyrethermalsandwear.requestPitStop()");
                }

                function sendAxlePressureOverride(axle, value) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setAxleTyrePressureOverride(" +
                        JSON.stringify(axle) + "," + JSON.stringify(value) + ")"
                    );
                }

                function sendStagePitPressure(axle, value) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitTyrePressure(" +
                        JSON.stringify(axle) + "," + JSON.stringify(value) + ")"
                    );
                }

                function getPitTunedPsi(axle) {
                    var value = axle === "front" ? pitTunedFrontPsi : pitTunedRearPsi;
                    value = Number(value);
                    return isFinite(value) ? value : 30;
                }

                function normalisePitPsiText(raw, axle) {
                    var text = String(raw === undefined || raw === null ? "" : raw).trim();
                    if (!text || text.toUpperCase() === "AUTO") {
                        return getPitTunedPsi(axle).toFixed(1);
                    }
                    var psi = Number(text);
                    if (!isFinite(psi)) return null;
                    psi = Math.max(0, psi);
                    return psi.toFixed(1);
                }

                function commitPitPsiInput(axle, input) {
                    if (!input) return;
                    var previous = Number(input.dataset.lastValidPsi);
                    var value = normalisePitPsiText(input.value, axle);
                    if (value === null) {
                        input.value = isFinite(previous) ? previous.toFixed(1) : getPitTunedPsi(axle).toFixed(1);
                        setStatus("Invalid " + axle.toUpperCase() + " PSI — enter a finite value ≥ 0 PSI");
                        return;
                    }
                    input.value = value;
                    input.dataset.lastValidPsi = value;
                    pitPendingPsi[axle] = Number(value);
                    if (racingModeEnabled) {
                        sendStagePitPressure(axle, value);
                        stagePitWaitingLocally();
                        setStatus("Staged " + axle.toUpperCase() + " PSI: " + value + " — applies at PIT STOP");
                    } else {
                        sendAxlePressureOverride(axle, value);
                        setStatus(axle.toUpperCase() + " PSI forced immediately to " + value);
                    }
                }

                function updatePitPressureInputs(dataStream) {
                    pitTunedFrontPsi = Number(dataStream.tyre_pressure_tuned_front_psi);
                    pitTunedRearPsi = Number(dataStream.tyre_pressure_tuned_rear_psi);

                    function setOne(axle, input, overrideValue, liveValue, tunedValue) {
                        if (!input) return;
                        input.classList.toggle("staged", racingModeEnabled);
                        var live = Number(liveValue);
                        var tuned = Number(tunedValue);
                        input.title = (racingModeEnabled
                            ? "Racing Mode COLD/tuning PSI. At pit completion the fresh tyre is reset cold, this pressure is applied, then QUICK/SOAKED preheat raises live PSI naturally. "
                            : "Editable axle LIVE gauge PSI. ") +
                            (isFinite(tuned) ? ("Original tuning pressure: " + tuned.toFixed(1) + " PSI. ") : "") +
                            (isFinite(live) ? ("Current axle average: " + live.toFixed(1) + " PSI. ") : "") +
                            (racingModeEnabled
                                ? "Edits are staged until the 15 s pit stop finishes."
                                : "Normal mode: edits are forced immediately.") +
                            " Entering AUTO or leaving it blank resets this axle to its original tuned PSI.";
                        if (document.activeElement === input || input.dataset.editing === "1") return;
                        var numeric = Number(overrideValue);
                        var pendingRaw = pitPendingPsi[axle];
                        var hasPending = pendingRaw !== null && pendingRaw !== undefined && pendingRaw !== "";
                        if (hasPending) {
                            var pending = Number(pendingRaw);
                            if (isFinite(pending)) {
                                if (isFinite(numeric) && Math.abs(numeric - pending) < 0.051) {
                                    pitPendingPsi[axle] = null;
                                } else {
                                    numeric = pending;
                                }
                            } else {
                                pitPendingPsi[axle] = null;
                            }
                        }
                        if (!isFinite(numeric)) numeric = tuned;
                        if (!isFinite(numeric)) numeric = 30;
                        input.value = numeric.toFixed(1);
                        input.dataset.lastValidPsi = numeric.toFixed(1);
                    }

                    setOne(
                        "front",
                        pitFrontPsiInput,
                        racingModeEnabled ? dataStream.pit_stop_staged_front_psi : dataStream.tyre_pressure_override_front_psi,
                        dataStream.tyre_pressure_live_front_psi,
                        dataStream.tyre_pressure_tuned_front_psi
                    );
                    setOne(
                        "rear",
                        pitRearPsiInput,
                        racingModeEnabled ? dataStream.pit_stop_staged_rear_psi : dataStream.tyre_pressure_override_rear_psi,
                        dataStream.tyre_pressure_live_rear_psi,
                        dataStream.tyre_pressure_tuned_rear_psi
                    );
                }

                function updateRacingModeButton(enabled) {
                    var wasRacingModeEnabled = racingModeEnabled;
                    racingModeEnabled = enabled === true;
                    if (wasRacingModeEnabled && !racingModeEnabled) updatePreheatButtonMode("quick");
                    if (racingModeButton) {
                        racingModeButton.classList.toggle("active", racingModeEnabled);
                        racingModeButton.setAttribute("aria-pressed", racingModeEnabled ? "true" : "false");
                        racingModeButton.textContent = racingModeEnabled ? "RACING MODE — ON" : "RACING MODE — OFF";
                    }
                    if (pitStopButton) pitStopButton.hidden = !racingModeEnabled;
                    if (preheatButton) {
                        preheatButton.disabled = false;
                        preheatButton.removeAttribute("aria-disabled");
                        preheatButton.title = racingModeEnabled
                            ? "Racing Mode: click to stage QUICK → SOAKED → COLD for the NEXT tyre set only; PIT STOP applies it at the typed temperature."
                            : "Click applies the mode shown now: QUICK = operating-window radial gradient; SOAKED = whole tyre/rim/cavity at the typed temperature. The next click alternates mode.";
                    }
                    if (pitProgress) pitProgress.hidden = false;
                    if (!racingModeEnabled) {
                        setPitProgressState("off", "PIT MANAGER", 0, 0);
                    }
                    if (pitPressureHeading) pitPressureHeading.textContent = racingModeEnabled
                        ? "TYRE PRESSURE — COLD / TUNE PSI"
                        : "TYRE PRESSURE OVERRIDE — LIVE PSI";
                    if (pitFrontPsiInput) pitFrontPsiInput.classList.toggle("staged", racingModeEnabled);
                    if (pitRearPsiInput) pitRearPsiInput.classList.toggle("staged", racingModeEnabled);
                }

                function setPitProgressState(state, message, progress, remainingS) {
                    pitStopState = String(state || "off");
                    if (!pitProgress || !pitProgressFill || !pitProgressText) return;

                    var safeProgress = Math.max(0, Math.min(1, Number(progress) || 0));
                    pitProgress.classList.remove("idle", "finished", "ready", "reject");
                    if (pitStopState === "idle" || pitStopState === "off") {
                        pitProgress.classList.add("idle");
                        safeProgress = 0;
                    } else if (pitStopState === "finished") {
                        pitProgress.classList.add("finished");
                        safeProgress = 1;
                    } else if (pitStopState === "ready") {
                        pitProgress.classList.add("ready");
                        safeProgress = 1;
                    } else if (pitStopState === "must_stop") {
                        pitProgress.classList.add("reject");
                        safeProgress = 1;
                    } else if (pitStopState === "waiting") {
                        safeProgress = 1;
                    }

                    pitProgressFill.style.width = (safeProgress * 100).toFixed(1) + "%";
                    if (pitStopState === "countdown") {
                        var remain = Math.max(0, Number(remainingS) || 0);
                        pitProgressText.textContent = "PIT STOP — " + remain.toFixed(1) + "s";
                    } else {
                        pitProgressText.textContent = (pitStopState === "idle" || pitStopState === "off")
                            ? "PIT MANAGER"
                            : String(message || "PIT MANAGER");
                    }
                    if (pitStopButton) pitStopButton.disabled = pitStopState === "countdown";
                }

                function stagePitWaitingLocally() {
                    if (!racingModeEnabled) return;
                    setPitProgressState("waiting", "WAITING PIT STOP", 1, 0);
                }

                function updateCompoundSectionVisibility() {
                    if (slickCompoundSection) slickCompoundSection.hidden = currentTyreProfilePreset !== "race";
                    if (rallyCompoundSection) rallyCompoundSection.hidden = currentTyreProfilePreset !== "rally";
                }

                function updateSlickCompoundPresetButtons(compoundId) {
                    compoundId = String(compoundId || "medium").toLowerCase();
                    currentSlickCompoundPreset = compoundId;
                    Object.keys(slickCompoundPresetButtons).forEach(function (key) {
                        var button = slickCompoundPresetButtons[key];
                        var active = key === compoundId;
                        button.classList.toggle("active", active);
                        button.setAttribute("aria-pressed", active ? "true" : "false");
                    });
                }

                function updateRallySurfacePresetButtons(surfaceId) {
                    surfaceId = String(surfaceId || "asphalt").toLowerCase();
                    currentRallySurfacePreset = surfaceId;
                    Object.keys(rallySurfacePresetButtons).forEach(function (key) {
                        var button = rallySurfacePresetButtons[key];
                        var active = key === surfaceId;
                        button.classList.toggle("active", active);
                        button.setAttribute("aria-pressed", active ? "true" : "false");
                    });
                }

                function updateRallyCompoundPresetButtons(compoundId) {
                    compoundId = String(compoundId || "medium").toLowerCase();
                    currentRallyCompoundPreset = compoundId;
                    Object.keys(rallyCompoundPresetButtons).forEach(function (key) {
                        var button = rallyCompoundPresetButtons[key];
                        var active = key === compoundId;
                        button.classList.toggle("active", active);
                        button.setAttribute("aria-pressed", active ? "true" : "false");
                    });
                }

                function saveStructuralPsiOverrides() {
                    try { localStorage.setItem(structuralPsiStorageKey, JSON.stringify(structuralPsiOverrides)); } catch (e) {}
                }

                function sendTyreStructuralPsi(internalName, value) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.setTyreStructuralPressureTarget(" + JSON.stringify(internalName) + "," + Number(value) + ")"
                    );
                }

                function clearTyreStructuralPsi(internalName) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.clearTyreStructuralPressureTarget(" + JSON.stringify(internalName) + ")"
                    );
                }

                function sendTyrePreheat(mode, targetC) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.preheatTyres(" +
                        JSON.stringify(String(mode || "quick")) + "," + Number(targetC) + ")"
                    );
                }

                function sendStagePitPreheat(mode, targetC) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitPreheat(" +
                        JSON.stringify(String(mode || "quick")) + "," + Number(targetC) + ")"
                    );
                }

                function clampPreheatTemperature(value, fallback) {
                    value = Number(value);
                    if (!isFinite(value)) value = Number(fallback);
                    if (!isFinite(value)) value = 70;
                    return Math.max(-100, Math.min(500, value));
                }

                function advancedPreheatTargetsLua(targets) {
                    targets = targets || {};
                    return "{FL=" + clampPreheatTemperature(targets.FL, 70) +
                        ",FR=" + clampPreheatTemperature(targets.FR, 70) +
                        ",RL=" + clampPreheatTemperature(targets.RL, 70) +
                        ",RR=" + clampPreheatTemperature(targets.RR, 70) + "}";
                }

                function sendTyrePreheatAdvanced(mode, targets) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.preheatTyresAdvanced(" +
                        JSON.stringify(String(mode || "quick")) + "," + advancedPreheatTargetsLua(targets) + ")"
                    );
                }

                function sendStagePitPreheatAdvanced(mode, targets) {
                    return queueVehicleCommand(
                        "extensions.luukstyrethermalsandwear.stagePitPreheatAdvanced(" +
                        JSON.stringify(String(mode || "quick")) + "," + advancedPreheatTargetsLua(targets) + ")"
                    );
                }

                function loadAdvancedPreheatState() {
                    try {
                        var raw = JSON.parse(localStorage.getItem(advancedPreheatStorageKey) || "null");
                        if (!raw || typeof raw !== "object") return;
                        advancedPreheatState.custom = raw.custom === true;
                        advancedPreheatState.open = raw.open === true;
                        advancedPreheatState.linkLR = raw.linkLR === true;
                        advancedPreheatState.linkFR = raw.linkFR === true;
                        if (advancedPreheatState.linkLR && advancedPreheatState.linkFR) advancedPreheatState.linkFR = false;
                        ["FL","FR","RL","RR"].forEach(function (key) {
                            if (raw.temps && isFinite(Number(raw.temps[key])))
                                advancedPreheatState.temps[key] = clampPreheatTemperature(raw.temps[key], 70);
                        });
                    } catch (e) {}
                }

                function saveAdvancedPreheatState() {
                    try { localStorage.setItem(advancedPreheatStorageKey, JSON.stringify(advancedPreheatState)); } catch (e) {}
                }

                function syncAdvancedPreheatToGlobal(force) {
                    if (advancedPreheatState.custom && !force) return;
                    var value = getPreheatTemperature();
                    advancedPreheatState.temps.FL = value; advancedPreheatState.temps.FR = value;
                    advancedPreheatState.temps.RL = value; advancedPreheatState.temps.RR = value;
                    if (force) {
                        advancedPreheatState.custom = false;
                        advancedPreheatState.linkLR = false;
                        advancedPreheatState.linkFR = false;
                    }
                    saveAdvancedPreheatState();
                    renderAdvancedPreheatPanel();
                }

                function getAdvancedPreheatTargets() {
                    return {
                        FL: clampPreheatTemperature(advancedPreheatState.temps.FL, getPreheatTemperature()),
                        FR: clampPreheatTemperature(advancedPreheatState.temps.FR, getPreheatTemperature()),
                        RL: clampPreheatTemperature(advancedPreheatState.temps.RL, getPreheatTemperature()),
                        RR: clampPreheatTemperature(advancedPreheatState.temps.RR, getPreheatTemperature())
                    };
                }

                function stageOrApplyPreheat(mode, target, racing) {
                    if (advancedPreheatState.open) {
                        var targets = getAdvancedPreheatTargets();
                        return racing ? sendStagePitPreheatAdvanced(mode, targets) : sendTyrePreheatAdvanced(mode, targets);
                    }
                    return racing ? sendStagePitPreheat(mode, target) : sendTyrePreheat(mode, target);
                }

                function unifyAdvancedPreheatPair(keys) {
                    var a = clampPreheatTemperature(advancedPreheatState.temps[keys[0]], getPreheatTemperature());
                    var b = clampPreheatTemperature(advancedPreheatState.temps[keys[1]], getPreheatTemperature());
                    var avg = (a + b) * 0.5;
                    advancedPreheatState.temps[keys[0]] = avg;
                    advancedPreheatState.temps[keys[1]] = avg;
                }

                function setAdvancedPreheatLink(kind) {
                    if (kind === "lr") {
                        var nextLR = !advancedPreheatState.linkLR;
                        advancedPreheatState.linkLR = nextLR;
                        if (nextLR) {
                            advancedPreheatState.linkFR = false;
                            unifyAdvancedPreheatPair(["FL","FR"]);
                            unifyAdvancedPreheatPair(["RL","RR"]);
                        }
                    } else {
                        var nextFR = !advancedPreheatState.linkFR;
                        advancedPreheatState.linkFR = nextFR;
                        if (nextFR) {
                            advancedPreheatState.linkLR = false;
                            unifyAdvancedPreheatPair(["FL","RL"]);
                            unifyAdvancedPreheatPair(["FR","RR"]);
                        }
                    }
                    advancedPreheatState.custom = true;
                    saveAdvancedPreheatState();
                    renderAdvancedPreheatPanel();
                    if (racingModeEnabled) {
                        sendStagePitPreheatAdvanced(preheatUiMode, getAdvancedPreheatTargets());
                        stagePitWaitingLocally();
                    }
                }

                function makeAdvancedPreheatInput(label, keys) {
                    var box = document.createElement("div");
                    box.className = "tyre-preheat-corner-box";
                    var lab = document.createElement("span");
                    lab.className = "tyre-preheat-corner-label";
                    lab.textContent = label;
                    box.appendChild(lab);
                    var wrap = document.createElement("div");
                    wrap.className = "tyre-preheat-corner-input-wrap";
                    var input = document.createElement("input");
                    input.type = "text"; input.inputMode = "decimal";
                    input.className = "tyre-preheat-corner-input";
                    var sum = 0; keys.forEach(function (key) { sum += clampPreheatTemperature(advancedPreheatState.temps[key], getPreheatTemperature()); });
                    input.value = (sum / keys.length).toFixed(1);
                    input.dataset.lastValidTemp = input.value;
                    function commit() {
                        var value = Number(input.value);
                        if (!isFinite(value)) { input.value = input.dataset.lastValidTemp || "70.0"; return; }
                        value = clampPreheatTemperature(value, getPreheatTemperature());
                        input.value = value.toFixed(1); input.dataset.lastValidTemp = input.value;
                        keys.forEach(function (key) { advancedPreheatState.temps[key] = value; });
                        advancedPreheatState.custom = true;
                        saveAdvancedPreheatState();
                        if (racingModeEnabled) {
                            sendStagePitPreheatAdvanced(preheatUiMode, getAdvancedPreheatTargets());
                            stagePitWaitingLocally();
                            setStatus("Advanced pit preheat staged");
                        }
                    }
                    input.addEventListener("mousedown", function (event) {
                        activeTuningInput = input; activeTuningDefinition = null; setKeyboardCapture(true, input); event.stopPropagation();
                    });
                    input.addEventListener("click", stopUiPropagation);
                    input.addEventListener("focus", function () {
                        activeTuningInput = input; activeTuningDefinition = null; setKeyboardCapture(true, input);
                        try { input.select(); } catch (e) {}
                    });
                    input.addEventListener("change", commit);
                    input.addEventListener("blur", function () { commit(); if (activeTuningInput === input) { activeTuningInput = null; setKeyboardCapture(false); } });
                    input.addEventListener("keydown", function (event) {
                        if (event.key === "Enter") { commit(); try { input.blur(); } catch (e) {} event.preventDefault(); }
                        else if (event.key === "Escape") { input.value = input.dataset.lastValidTemp || "70.0"; try { input.blur(); } catch (e) {} event.preventDefault(); }
                        event.stopPropagation();
                    });
                    input.addEventListener("keyup", stopUiPropagation);
                    input.addEventListener("keypress", stopUiPropagation);
                    wrap.appendChild(input);
                    var unit = document.createElement("span"); unit.className = "tyre-preheat-corner-unit"; unit.textContent = "°C"; wrap.appendChild(unit);
                    box.appendChild(wrap);
                    return box;
                }

                function renderAdvancedPreheatPanel() {
                    if (advancedPreheatToggle) {
                        advancedPreheatToggle.classList.toggle("active", advancedPreheatState.open);
                        advancedPreheatToggle.textContent = "ADVANCED PREHEAT " + (advancedPreheatState.open ? "▾" : "▸") +
                            (advancedPreheatState.custom && !advancedPreheatState.open ? "  • SAVED" : "");
                        advancedPreheatToggle.setAttribute("aria-expanded", advancedPreheatState.open ? "true" : "false");
                    }
                    if (advancedPreheatPanel) advancedPreheatPanel.hidden = !advancedPreheatState.open;
                    if (advancedPreheatLinkLRButton) {
                        advancedPreheatLinkLRButton.classList.toggle("active", advancedPreheatState.linkLR);
                        advancedPreheatLinkLRButton.textContent = (advancedPreheatState.linkLR ? "✓ " : "") + "LINK LEFT / RIGHT";
                    }
                    if (advancedPreheatLinkFRButton) {
                        advancedPreheatLinkFRButton.classList.toggle("active", advancedPreheatState.linkFR);
                        advancedPreheatLinkFRButton.textContent = (advancedPreheatState.linkFR ? "✓ " : "") + "LINK FRONT / REAR";
                    }
                    if (!advancedPreheatGrid) return;
                    advancedPreheatGrid.classList.remove("mode-corners", "mode-lr", "mode-fr");
                    advancedPreheatGrid.classList.add(advancedPreheatState.linkLR ? "mode-lr" :
                        (advancedPreheatState.linkFR ? "mode-fr" : "mode-corners"));
                    while (advancedPreheatGrid.firstChild) advancedPreheatGrid.removeChild(advancedPreheatGrid.firstChild);
                    if (advancedPreheatState.linkLR) {
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("FRONT", ["FL","FR"]));
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("REAR", ["RL","RR"]));
                    } else if (advancedPreheatState.linkFR) {
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("LEFT", ["FL","RL"]));
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("RIGHT", ["FR","RR"]));
                    } else {
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("FRONT LEFT", ["FL"]));
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("FRONT RIGHT", ["FR"]));
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("REAR LEFT", ["RL"]));
                        advancedPreheatGrid.appendChild(makeAdvancedPreheatInput("REAR RIGHT", ["RR"]));
                    }
                }

                function normalisePreheatUiMode(mode) {
                    mode = String(mode || "quick").toLowerCase();
                    return (mode === "soaked" || mode === "cold") ? mode : "quick";
                }

                function updatePreheatButtonMode(mode) {
                    preheatUiMode = normalisePreheatUiMode(mode);
                    if (!preheatButton) return;
                    preheatButton.classList.toggle("preheat-soaked", preheatUiMode === "soaked");
                    preheatButton.classList.toggle("preheat-cold", preheatUiMode === "cold");
                    preheatButton.textContent = preheatUiMode === "cold" ? "COLD" :
                        (preheatUiMode === "soaked" ? "PREHEAT: SOAKED" : "PREHEAT: QUICK");
                }

                function getPreheatTemperature() {
                    var value = preheatTempInput ? Number(preheatTempInput.value) : NaN;
                    if (!isFinite(value)) value = 70;
                    return Math.max(-100, Math.min(500, value));
                }

                function commitPreheatTemperature() {
                    if (!preheatTempInput) return;
                    var value = Number(preheatTempInput.value);
                    if (!isFinite(value)) {
                        preheatTempInput.classList.add("invalid");
                        setStatus("Invalid preheat temperature");
                        return;
                    }
                    value = Math.max(-100, Math.min(500, value));
                    preheatTempInput.value = value.toFixed(1);
                    preheatTempInput.dataset.lastValidTemp = value.toFixed(1);
                    preheatTempInput.classList.remove("invalid");
                    preheatTempUserEdited = true;
                    if (!advancedPreheatState.custom) syncAdvancedPreheatToGlobal(false);
                    if (racingModeEnabled) {
                        stageOrApplyPreheat(preheatUiMode, value, true);
                        stagePitWaitingLocally();
                        setStatus(advancedPreheatState.open ? "Advanced pit preheat staged" :
                            ("Pit tyre thermal state staged: " +
                            (preheatUiMode === "cold" ? "COLD" : preheatUiMode.toUpperCase()) +
                            " @ " + value.toFixed(1) + "°C"));
                    }
                }

                function updateTyreProfilePresetButtons(profileId) {
                    profileId = String(profileId || "auto").toLowerCase();
                    currentTyreProfilePreset = profileId;
                    Object.keys(tyreProfilePresetButtons).forEach(function (key) {
                        var button = tyreProfilePresetButtons[key];
                        var active = key === profileId;
                        button.classList.toggle("active", active);
                        button.setAttribute("aria-pressed", active ? "true" : "false");
                    });
                    updateCompoundSectionVisibility();
                }

                function getEffectiveDefinitionMax(definition) {
                    return definition.max;
                }

                function commitInput(input, definition) {
                    var inputText = String(input.value || "").trim();
                    var value;
                    if (definition.key === "working_temp_c" && inputText.toUpperCase() === "AUTO") {
                        value = -1;
                    } else {
                        var displayedValue = Number(inputText);
                        if (!isFinite(displayedValue)) {
                            input.classList.add("invalid");
                            setStatus("Invalid number: " + definition.label);
                            return;
                        }
                        value = nativePercentToRaw(definition, displayedValue);
                    }
                    if (!isFinite(value)) {
                        input.classList.add("invalid");
                        setStatus("Invalid number: " + definition.label);
                        return;
                    }
                    value = Math.max(definition.min, Math.min(getEffectiveDefinitionMax(definition), value));
                    input.classList.remove("invalid");
                    input.value = formatTuningValue(definition, value);
                    currentTuningValues[definition.key] = value;
                    sendTuningValue(definition.key, value);
                    setStatus(tuningDisplayLabel(definition) + " = " + formatTuningValue(definition, value) + ((usesDirectPercent(definition) || usesNativePercent(definition)) ? "%" : (definition.valueUnitLabel ? String(definition.valueUnitLabel) : "")));
                }

                function insertAtSelection(input, text) {
                    if (!input) return;
                    if (activeTuningDefinition && activeTuningDefinition.key === "working_temp_c" &&
                        String(input.value || "").trim().toUpperCase() === "AUTO") {
                        input.value = "";
                    }
                    var start = typeof input.selectionStart === "number" ? input.selectionStart : input.value.length;
                    var end = typeof input.selectionEnd === "number" ? input.selectionEnd : start;
                    input.value = input.value.slice(0, start) + text + input.value.slice(end);
                    var cursor = start + text.length;
                    refocusInput(input);
                    window.setTimeout(function () {
                        try { input.setSelectionRange(cursor, cursor); } catch (ignored) {}
                    }, 0);
                }

                function backspaceAtSelection(input) {
                    if (!input) return;
                    var start = typeof input.selectionStart === "number" ? input.selectionStart : input.value.length;
                    var end = typeof input.selectionEnd === "number" ? input.selectionEnd : start;
                    if (start === end && start > 0) start -= 1;
                    input.value = input.value.slice(0, start) + input.value.slice(end);
                    refocusInput(input);
                    window.setTimeout(function () {
                        try { input.setSelectionRange(start, start); } catch (ignored) {}
                    }, 0);
                }

                function selectWholeInput(input) {
                    if (!input) return;
                    refocusInput(input);
                    window.setTimeout(function () {
                        try { input.setSelectionRange(0, input.value.length); } catch (ignored) {}
                    }, 0);
                }

                function buildSettingsPanel() {
                    tyreProfileCard = document.createElement("section");
                    tyreProfileCard.className = "tyre-profile-card";

                    racingModeButton = document.createElement("button");
                    racingModeButton.type = "button";
                    racingModeButton.className = "tyre-racing-mode-toggle";
                    racingModeButton.setAttribute("aria-pressed", "false");
                    racingModeButton.textContent = "RACING MODE — OFF";
                    racingModeButton.title = "When enabled, tyre preset/compound buttons stage the next set instead of applying immediately. Press PIT STOP while fully stopped to fit fresh tyres after 15 seconds using the staged COLD / QUICK / SOAKED thermal state.";
                    racingModeButton.addEventListener("click", function (event) {
                        var next = !racingModeEnabled;
                        updateRacingModeButton(next);
                        if (next) {
                            updatePreheatButtonMode("quick");
                            updateTyreProfilePresetButtons(appliedTyreProfilePreset);
                            updateSlickCompoundPresetButtons(appliedSlickCompoundPreset);
                            updateRallySurfacePresetButtons(appliedRallySurfacePreset);
                            updateRallyCompoundPresetButtons(appliedRallyCompoundPreset);
                            setPitProgressState("waiting", "WAITING PIT STOP", 1, 0);
                            setStatus("Racing Mode ON — tyre choices are staged until PIT STOP");
                        } else {
                            updateTyreProfilePresetButtons(appliedTyreProfilePreset);
                            updateSlickCompoundPresetButtons(appliedSlickCompoundPreset);
                            updateRallySurfacePresetButtons(appliedRallySurfacePreset);
                            updateRallyCompoundPresetButtons(appliedRallyCompoundPreset);
                            setPitProgressState("off", "PIT MANAGER", 0, 0);
                            setStatus("Racing Mode OFF — tyre presets and PSI apply immediately");
                        }
                        sendRacingPitMode(next);
                        if (next) stageOrApplyPreheat("quick", getPreheatTemperature(), true);
                        event.preventDefault();
                        event.stopPropagation();
                    });
                    tyreProfileCard.appendChild(racingModeButton);

                    pitProgress = document.createElement("div");
                    pitProgress.className = "tyre-pit-progress idle";
                    pitProgress.hidden = false;
                    pitProgressFill = document.createElement("div");
                    pitProgressFill.className = "tyre-pit-progress-fill";
                    pitProgressText = document.createElement("div");
                    pitProgressText.className = "tyre-pit-progress-text";
                    pitProgressText.textContent = "PIT MANAGER";
                    pitProgress.appendChild(pitProgressFill);
                    pitProgress.appendChild(pitProgressText);
                    tyreProfileCard.appendChild(pitProgress);

                    pitPressureHeading = document.createElement("div");
                    pitPressureHeading.className = "tyre-pit-pressure-heading";
                    pitPressureHeading.textContent = "TYRE PRESSURE OVERRIDE — LIVE PSI";
                    tyreProfileCard.appendChild(pitPressureHeading);

                    var pressureGrid = document.createElement("div");
                    pressureGrid.className = "tyre-pit-pressure-grid";
                    function makePressureInput(axle, label) {
                        var box = document.createElement("label");
                        box.className = "tyre-pit-pressure-box";
                        var cap = document.createElement("span");
                        cap.className = "tyre-pit-pressure-label";
                        cap.textContent = label;
                        var input = document.createElement("input");
                        input.type = "text";
                        input.inputMode = "decimal";
                        input.className = "tyre-pit-pressure-input";
                        input.value = "30.0";
                        input.dataset.lastValidPsi = "30.0";
                        input.dataset.editing = "0";
                        input.autocomplete = "off";
                        input.spellcheck = false;

                        function ownPitPsiEditor(selectAll) {
                            activeTuningInput = input;
                            activeTuningDefinition = null;
                            input.dataset.editing = "1";
                            setKeyboardCapture(true, input);
                            if (selectAll) {
                                window.setTimeout(function () {
                                    try { input.select(); } catch (ignoredSelect) {}
                                }, 0);
                            }
                        }

                        input.addEventListener("mousedown", function (event) {
                            ownPitPsiEditor(false);
                            event.stopPropagation();
                        });
                        input.addEventListener("click", stopUiPropagation);
                        input.addEventListener("focus", function () {
                            ownPitPsiEditor(true);
                        });
                        input.addEventListener("input", function (event) {
                            input.dataset.editing = "1";
                            event.stopPropagation();
                        });
                        input.addEventListener("keyup", stopUiPropagation);
                        input.addEventListener("keypress", stopUiPropagation);
                        input.addEventListener("keydown", function (event) {
                            if (event.key === "Enter") {
                                commitPitPsiInput(axle, input);
                                input.dataset.editing = "0";
                                try { input.blur(); } catch (ignoredBlur) {}
                                event.preventDefault();
                            } else if (event.key === "Escape") {
                                var previous = Number(input.dataset.lastValidPsi);
                                input.value = isFinite(previous) ? previous.toFixed(1) : getPitTunedPsi(axle).toFixed(1);
                                input.dataset.editing = "0";
                                try { input.blur(); } catch (ignoredEscapeBlur) {}
                                event.preventDefault();
                            }
                            event.stopPropagation();
                        });
                        input._commitPitPsi = function () {
                            commitPitPsiInput(axle, input);
                            input.dataset.editing = "0";
                        };
                        input.addEventListener("blur", function () {
                            if (input.dataset.editing === "1") commitPitPsiInput(axle, input);
                            input.dataset.editing = "0";
                            if (activeTuningInput === input) {
                                activeTuningInput = null;
                                activeTuningDefinition = null;
                                setKeyboardCapture(false);
                            }
                        });
                        box.appendChild(cap);
                        box.appendChild(input);
                        pressureGrid.appendChild(box);
                        return input;
                    }
                    pitFrontPsiInput = makePressureInput("front", "FRONT PSI");
                    pitRearPsiInput = makePressureInput("rear", "REAR PSI");
                    tyreProfileCard.appendChild(pressureGrid);

                    var heading = document.createElement("div");
                    heading.className = "tyre-profile-heading";
                    heading.textContent = "Auto tyre profile — detecting…";
                    tyreProfileLines = document.createElement("div");
                    tyreProfileLines.className = "tyre-profile-line";
                    tyreProfileLines.textContent = "Waiting for tyre part names";
                    tyreProfileNote = document.createElement("div");
                    tyreProfileNote.className = "tyre-profile-note";
                    tyreProfileNote.textContent = "Pressure target: Vehicle Configuration > Tuning (per wheel).";
                    tyreProfileNote.title = tyreProfileNote.textContent;
                    tyreActiveThermal = null;
                    tyreProfileCard.appendChild(heading);
                    tyreProfileCard.appendChild(tyreProfileLines);
                    tyreProfileCard.appendChild(tyreProfileNote);

                    var presetBar = document.createElement("div");
                    presetBar.className = "tyre-profile-presets";
                    [
                        { id: "auto", label: "AUTO" },
                        { id: "standard", label: "STANDARD" },
                        { id: "sport", label: "SPORT" },
                        { id: "semi_slick", label: "SEMI-SLICK" },
                        { id: "race", label: "RACE" },
                        { id: "rally", label: "RALLY" },
                        { id: "drift", label: "DRIFT" }
                    ].forEach(function (preset) {
                        var button = document.createElement("button");
                        button.type = "button";
                        button.className = "tyre-profile-preset";
                        button.textContent = preset.label;
                        button.title = preset.id === "auto"
                            ? "Use each tyre's detected part-name profile"
                            : "Force " + preset.label + " profile on every tyre";
                        button.setAttribute("aria-pressed", "false");
                        button.addEventListener("click", function (event) {
                            updateTyreProfilePresetButtons(preset.id);
                            if (racingModeEnabled) {
                                sendStagePitTyreProfile(preset.id);
                                stagePitWaitingLocally();
                                setStatus("Staged pit tyre: " + preset.label + " — press PIT STOP to apply");
                            } else {
                                updateProfilePresetReadOnly(preset.id === "auto");
                                if (sendTyreProfilePreset(preset.id)) {
                                    setStatus(preset.id === "auto"
                                        ? "Automatic tyre profile enabled"
                                        : preset.label + " profile applied to all tyres");
                                }
                            }
                            event.preventDefault();
                            event.stopPropagation();
                        });
                        tyreProfilePresetButtons[preset.id] = button;
                        presetBar.appendChild(button);
                    });
                    tyreProfileCard.appendChild(presetBar);

                    slickCompoundSection = document.createElement("div");
                    slickCompoundSection.className = "tyre-compound-section";
                    var slickHeading = document.createElement("div");
                    slickHeading.className = "tyre-slick-heading";
                    slickHeading.textContent = "RACE COMPOUND";
                    slickCompoundSection.appendChild(slickHeading);
                    var slickBar = document.createElement("div");
                    slickBar.className = "tyre-slick-presets";
                    [
                        { id: "supersoft", label: "SS", title: "Super Soft: lowest working window, +5% peak road grip, shortest life" },
                        { id: "soft", label: "S", title: "Soft: lower working window, +3% peak grip, faster wear" },
                        { id: "medium", label: "M", title: "Medium: balanced generic slick baseline" },
                        { id: "hard", label: "H", title: "Hard: higher working window, -2% peak grip, slower wear" }
                    ].forEach(function (compound) {
                        var button = document.createElement("button");
                        button.type = "button";
                        button.className = "tyre-slick-preset";
                        button.textContent = compound.label;
                        button.title = compound.title;
                        button.setAttribute("aria-pressed", "false");
                        button.addEventListener("click", function (event) {
                            updateSlickCompoundPresetButtons(compound.id);
                            if (racingModeEnabled) {
                                sendStagePitSlickCompound(compound.id);
                                stagePitWaitingLocally();
                                setStatus("Staged race compound: " + compound.id.toUpperCase());
                            } else if (sendSlickCompoundPreset(compound.id)) {
                                setStatus("Slick compound: " + compound.id.toUpperCase());
                            }
                            event.preventDefault();
                            event.stopPropagation();
                        });
                        slickCompoundPresetButtons[compound.id] = button;
                        slickBar.appendChild(button);
                    });
                    slickCompoundSection.appendChild(slickBar);
                    tyreProfileCard.appendChild(slickCompoundSection);

                    rallyCompoundSection = document.createElement("div");
                    rallyCompoundSection.className = "tyre-compound-section";
                    var rallySurfaceHeading = document.createElement("div");
                    rallySurfaceHeading.className = "tyre-slick-heading";
                    rallySurfaceHeading.textContent = "RALLY SURFACE";
                    rallyCompoundSection.appendChild(rallySurfaceHeading);
                    var rallySurfaceBar = document.createElement("div");
                    rallySurfaceBar.className = "tyre-rally-surface-presets";
                    [
                        { id: "asphalt", label: "ASPHALT", title: "18-inch shallow-tread tarmac-rally profile. On terrain, BeamNG native ground physics stays active and the dirt overlay replaces the road curve." },
                        { id: "gravel", label: "GRAVEL", title: "15-inch deep-block gravel-rally profile. On terrain, BeamNG native ground physics plus dirt heat/block wear replaces the road curve." }
                    ].forEach(function (surface) {
                        var button = document.createElement("button");
                        button.type = "button";
                        button.className = "tyre-slick-preset";
                        button.textContent = surface.label;
                        button.title = surface.title;
                        button.setAttribute("aria-pressed", "false");
                        button.addEventListener("click", function (event) {
                            updateRallySurfacePresetButtons(surface.id);
                            if (racingModeEnabled) {
                                sendStagePitRallySurface(surface.id);
                                stagePitWaitingLocally();
                                setStatus("Staged rally surface: " + surface.label);
                            } else if (sendRallySurfacePreset(surface.id)) {
                                setStatus("Rally surface: " + surface.label);
                            }
                            event.preventDefault();
                            event.stopPropagation();
                        });
                        rallySurfacePresetButtons[surface.id] = button;
                        rallySurfaceBar.appendChild(button);
                    });
                    rallyCompoundSection.appendChild(rallySurfaceBar);

                    var rallyCompoundHeading = document.createElement("div");
                    rallyCompoundHeading.className = "tyre-slick-heading";
                    rallyCompoundHeading.textContent = "RALLY COMPOUND";
                    rallyCompoundSection.appendChild(rallyCompoundHeading);
                    var rallyCompoundBar = document.createElement("div");
                    rallyCompoundBar.className = "tyre-slick-presets";
                    [
                        { id: "supersoft", label: "SS", title: "Super Soft: 20–60°C dirt block window, 1.00 peak, fastest wear" },
                        { id: "soft", label: "S", title: "Soft: 50–90°C dirt block window, 1.00 peak" },
                        { id: "medium", label: "M", title: "Medium: 70–130°C dirt block window, 1.00 peak" },
                        { id: "hard", label: "H", title: "Hard: 90–150°C first-pass dirt block window, 1.00 peak, lowest wear" }
                    ].forEach(function (compound) {
                        var button = document.createElement("button");
                        button.type = "button";
                        button.className = "tyre-slick-preset";
                        button.textContent = compound.label;
                        button.title = compound.title;
                        button.setAttribute("aria-pressed", "false");
                        button.addEventListener("click", function (event) {
                            updateRallyCompoundPresetButtons(compound.id);
                            if (racingModeEnabled) {
                                sendStagePitRallyCompound(compound.id);
                                stagePitWaitingLocally();
                                setStatus("Staged rally compound: " + compound.label);
                            } else if (sendRallyCompoundPreset(compound.id)) {
                                setStatus("Rally compound: " + compound.label);
                            }
                            event.preventDefault();
                            event.stopPropagation();
                        });
                        rallyCompoundPresetButtons[compound.id] = button;
                        rallyCompoundBar.appendChild(button);
                    });
                    rallyCompoundSection.appendChild(rallyCompoundBar);
                    tyreProfileCard.appendChild(rallyCompoundSection);

                    pitStopButton = document.createElement("button");
                    pitStopButton.type = "button";
                    pitStopButton.className = "tyre-pit-stop-button";
                    pitStopButton.textContent = "PIT STOP";
                    pitStopButton.hidden = true;
                    pitStopButton.title = "Requires vehicle speed below 0.5 km/h. Locks throttle for 15 seconds, then fits the staged tyre preset/compound as fresh tyres and applies the staged COLD / QUICK / SOAKED thermal state.";
                    pitStopButton.addEventListener("click", function (event) {
                        if (racingModeEnabled && pitStopState !== "countdown") {
                            sendPitStopRequest();
                            setStatus("Pit stop request sent");
                        }
                        event.preventDefault();
                        event.stopPropagation();
                    });
                    tyreProfileCard.appendChild(pitStopButton);

                    var preheatRow = document.createElement("div");
                    preheatRow.className = "tyre-preheat-row";

                    preheatButton = document.createElement("button");
                    preheatButton.type = "button";
                    preheatButton.className = "tyre-preheat-button";
                    updatePreheatButtonMode("quick");
                    preheatButton.title = "QUICK uses the current operating-window radial gradient. SOAKED puts the entire tyre, core, sidewalls, cavity gas and rim at the typed target.";
                    preheatButton.addEventListener("click", function (event) {
                        var target = getPreheatTemperature();
                        if (racingModeEnabled) {
                            var nextMode = preheatUiMode === "quick" ? "soaked" :
                                (preheatUiMode === "soaked" ? "cold" : "quick");
                            updatePreheatButtonMode(nextMode);
                            stageOrApplyPreheat(nextMode, target, true);
                            stagePitWaitingLocally();
                            setStatus("Pit tyre thermal state staged: " +
                                (nextMode === "cold" ? "COLD" : nextMode.toUpperCase()) +
                                (nextMode === "cold" ? "" : " @ " + target.toFixed(1) + "°C"));
                        } else {
                            var appliedMode = preheatUiMode === "soaked" ? "soaked" : "quick";
                            if (stageOrApplyPreheat(appliedMode, target, false)) {
                                if (advancedPreheatState.open) {
                                    var t = getAdvancedPreheatTargets();
                                    setStatus("Advanced " + appliedMode.toUpperCase() + " preheat: FL " + t.FL.toFixed(1) +
                                        " / FR " + t.FR.toFixed(1) + " / RL " + t.RL.toFixed(1) + " / RR " + t.RR.toFixed(1) + "°C");
                                } else {
                                    setStatus(appliedMode === "soaked"
                                        ? "Heat-soaked complete tyre to " + target.toFixed(1) + "°C"
                                        : "Quick-preheated tyre gradient toward " + target.toFixed(1) + "°C");
                                }
                            }
                            updatePreheatButtonMode(appliedMode === "quick" ? "soaked" : "quick");
                        }
                        event.preventDefault();
                        event.stopPropagation();
                    });
                    preheatRow.appendChild(preheatButton);

                    var preheatTempWrap = document.createElement("div");
                    preheatTempWrap.className = "tyre-preheat-temp-wrap";
                    preheatTempInput = document.createElement("input");
                    preheatTempInput.type = "text";
                    preheatTempInput.inputMode = "decimal";
                    preheatTempInput.className = "tyre-preheat-temp-input";
                    preheatTempInput.value = "70.0";
                    preheatTempInput.dataset.lastValidTemp = "70.0";
                    preheatTempInput.title = "Preheat target °C. Initializes from the fitted tyre operating temperature; type any new target.";
                    function ownPreheatTempEditor(selectAll) {
                        activeTuningInput = preheatTempInput;
                        activeTuningDefinition = null;
                        setKeyboardCapture(true, preheatTempInput);
                        if (selectAll) window.setTimeout(function () {
                            try { preheatTempInput.select(); } catch (ignoredSelect) {}
                        }, 0);
                    }
                    preheatTempInput.addEventListener("mousedown", function (event) { ownPreheatTempEditor(false); event.stopPropagation(); });
                    preheatTempInput.addEventListener("click", stopUiPropagation);
                    preheatTempInput.addEventListener("focus", function () { ownPreheatTempEditor(true); });
                    preheatTempInput.addEventListener("input", function (event) { preheatTempUserEdited = true; event.stopPropagation(); });
                    preheatTempInput.addEventListener("keyup", stopUiPropagation);
                    preheatTempInput.addEventListener("keypress", stopUiPropagation);
                    preheatTempInput.addEventListener("change", commitPreheatTemperature);
                    preheatTempInput.addEventListener("blur", function () {
                        commitPreheatTemperature();
                        if (activeTuningInput === preheatTempInput) {
                            activeTuningInput = null; activeTuningDefinition = null; setKeyboardCapture(false);
                        }
                    });
                    preheatTempInput.addEventListener("keydown", function (event) {
                        if (event.key === "Enter") {
                            commitPreheatTemperature();
                            try { preheatTempInput.blur(); } catch (ignoredBlur) {}
                            event.preventDefault();
                        } else if (event.key === "Escape") {
                            preheatTempInput.value = preheatTempInput.dataset.lastValidTemp || "70.0";
                            try { preheatTempInput.blur(); } catch (ignoredEscapeBlur) {}
                            event.preventDefault();
                        }
                        event.stopPropagation();
                    });
                    preheatTempWrap.appendChild(preheatTempInput);
                    var preheatTempUnit = document.createElement("span");
                    preheatTempUnit.className = "tyre-preheat-temp-unit";
                    preheatTempUnit.textContent = "°C";
                    preheatTempWrap.appendChild(preheatTempUnit);
                    preheatRow.appendChild(preheatTempWrap);
                    tyreProfileCard.appendChild(preheatRow);

                    loadAdvancedPreheatState();
                    advancedPreheatToggle = document.createElement("button");
                    advancedPreheatToggle.type = "button";
                    advancedPreheatToggle.className = "tyre-preheat-advanced-toggle";
                    advancedPreheatToggle.addEventListener("click", function (event) {
                        advancedPreheatState.open = !advancedPreheatState.open;
                        saveAdvancedPreheatState();
                        renderAdvancedPreheatPanel();
                        if (racingModeEnabled) {
                            if (advancedPreheatState.open) sendStagePitPreheatAdvanced(preheatUiMode, getAdvancedPreheatTargets());
                            else sendStagePitPreheat(preheatUiMode, getPreheatTemperature());
                            stagePitWaitingLocally();
                        }
                        setStatus(advancedPreheatState.open ? "Advanced preheat active" : "Using global preheat target");
                        event.preventDefault(); event.stopPropagation();
                    });
                    tyreProfileCard.appendChild(advancedPreheatToggle);

                    advancedPreheatPanel = document.createElement("div");
                    advancedPreheatPanel.className = "tyre-preheat-advanced-panel";
                    var advTitle = document.createElement("div");
                    advTitle.className = "tyre-preheat-advanced-title";
                    var advTitleText = document.createElement("span");
                    advTitleText.textContent = "PER-TYRE PREHEAT TARGETS";
                    advTitle.appendChild(advTitleText);
                    var advReset = document.createElement("button");
                    advReset.type = "button"; advReset.className = "tyre-preheat-global-reset"; advReset.textContent = "USE GLOBAL";
                    advReset.title = "Disable Advanced Preheat and copy the outside global target to all four tyres.";
                    advReset.addEventListener("click", function (event) {
                        syncAdvancedPreheatToGlobal(true);
                        advancedPreheatState.open = false;
                        saveAdvancedPreheatState();
                        renderAdvancedPreheatPanel();
                        if (racingModeEnabled) { sendStagePitPreheat(preheatUiMode, getPreheatTemperature()); stagePitWaitingLocally(); }
                        setStatus("Using global preheat target");
                        event.preventDefault(); event.stopPropagation();
                    });
                    advTitle.appendChild(advReset);
                    advancedPreheatPanel.appendChild(advTitle);

                    var advLinks = document.createElement("div");
                    advLinks.className = "tyre-preheat-link-row";
                    advancedPreheatLinkLRButton = document.createElement("button");
                    advancedPreheatLinkLRButton.type = "button"; advancedPreheatLinkLRButton.className = "tyre-preheat-link";
                    advancedPreheatLinkLRButton.title = "Link left/right tyres on each axle. Shows FRONT and REAR targets only.";
                    advancedPreheatLinkLRButton.addEventListener("click", function (event) { setAdvancedPreheatLink("lr"); event.preventDefault(); event.stopPropagation(); });
                    advLinks.appendChild(advancedPreheatLinkLRButton);
                    advancedPreheatLinkFRButton = document.createElement("button");
                    advancedPreheatLinkFRButton.type = "button"; advancedPreheatLinkFRButton.className = "tyre-preheat-link";
                    advancedPreheatLinkFRButton.title = "Link front/rear tyres on each side. Shows LEFT and RIGHT targets only.";
                    advancedPreheatLinkFRButton.addEventListener("click", function (event) { setAdvancedPreheatLink("fr"); event.preventDefault(); event.stopPropagation(); });
                    advLinks.appendChild(advancedPreheatLinkFRButton);
                    advancedPreheatPanel.appendChild(advLinks);

                    advancedPreheatGrid = document.createElement("div");
                    advancedPreheatGrid.className = "tyre-preheat-corner-grid";
                    advancedPreheatPanel.appendChild(advancedPreheatGrid);
                    tyreProfileCard.appendChild(advancedPreheatPanel);
                    renderAdvancedPreheatPanel();
                    updateRacingModeButton(racingModeEnabled);

                    arcadeHandlingButton = document.createElement("button");
                    arcadeHandlingButton.type = "button";
                    arcadeHandlingButton.className = "tyre-arcade-mode-button";
                    arcadeHandlingButton.setAttribute("aria-pressed", "false");
                    arcadeHandlingButton.addEventListener("pointerdown", triggerArcadeHandlingToggle, true);
                    arcadeHandlingButton.addEventListener("mousedown", function (event) {
                        if (typeof window.PointerEvent === "undefined") {
                            triggerArcadeHandlingToggle(event);
                        } else {
                            event.stopPropagation();
                        }
                    }, true);
                    arcadeHandlingButton.addEventListener("touchstart", function (event) {
                        if (typeof window.PointerEvent === "undefined") triggerArcadeHandlingToggle(event);
                    }, { capture: true, passive: false });
                    arcadeHandlingButton.addEventListener("click", function (event) {
                        if (event.detail === 0) triggerArcadeHandlingToggle(event);
                        else {
                            event.preventDefault();
                            event.stopPropagation();
                        }
                    }, true);
                    arcadeHandlingButton.addEventListener("keydown", function (event) {
                        if (event.key === "Enter" || event.key === " ") {
                            triggerArcadeHandlingToggle(event);
                        }
                    });
                    tyreProfileCard.appendChild(arcadeHandlingButton);
                    updateArcadeHandlingButton(false);

                    settingsBody.appendChild(tyreProfileCard);
                    updateTyreProfilePresetButtons(currentTyreProfilePreset);
                    updateSlickCompoundPresetButtons(currentSlickCompoundPreset);
                    updateRallySurfacePresetButtons(currentRallySurfacePreset);
                    updateRallyCompoundPresetButtons(currentRallyCompoundPreset);
                    updateCompoundSectionVisibility();

                    var advancedButton = document.createElement("button");
                    advancedButton.type = "button";
                    advancedButton.className = "tyre-advanced-toggle";
                    advancedButton.textContent = "EXPERIMENTAL  ▸";
                    advancedButton.title = "Show experimental tyre-model controls. Preset-bound values are literal solver inputs in manual mode; when detection owns them they show the actual effective numeric preset values read-only.";
                    advancedButton.setAttribute("aria-expanded", "false");
                    var advancedContent = document.createElement("div");
                    advancedContent.className = "tyre-advanced-content";
                    advancedContent.hidden = true;
                    advancedButton.addEventListener("click", function (event) {
                        advancedContent.hidden = !advancedContent.hidden;
                        var open = !advancedContent.hidden;
                        advancedButton.textContent = open ? "EXPERIMENTAL  ▾" : "EXPERIMENTAL  ▸";
                        advancedButton.setAttribute("aria-expanded", open ? "true" : "false");
                        setStatus(open ? "Experimental controls shown" : "Experimental controls hidden");
                        event.preventDefault();
                        event.stopPropagation();
                    });
                    settingsBody.appendChild(advancedButton);
                    settingsBody.appendChild(advancedContent);

                    var debugGroup = document.createElement("section");
                    debugGroup.className = "tyre-settings-group";
                    var debugTitle = document.createElement("div");
                    debugTitle.className = "tyre-settings-group-title";
                    debugTitle.textContent = "Debug";
                    debugGroup.appendChild(debugTitle);
                    var debugRow = document.createElement("div");
                    debugRow.className = "tyre-setting-row";
                    debugRow.title = "Show live 12-cell tread calibration telemetry. Triple-click outside the Wear button to toggle Debug ON/OFF. While Debug is enabled, double-click outside the Wear button to toggle the transparent fullscreen four-wheel diagnostic view.";
                    var debugLabel = document.createElement("label");
                    debugLabel.className = "tyre-setting-label";
                    debugLabel.textContent = "Compact + fullscreen tyre telemetry";
                    debugLabel.htmlFor = "tyre-debug-temperatures";
                    debugTempCheckbox = document.createElement("input");
                    debugTempCheckbox.id = "tyre-debug-temperatures";
                    debugTempCheckbox.className = "tyre-setting-checkbox";
                    debugTempCheckbox.type = "checkbox";
                    debugTempCheckbox.checked = debugTempsEnabled;
                    debugTempCheckbox.addEventListener("change", function (event) {
                        debugTempsEnabled = debugTempCheckbox.checked === true;
                        syncVehicleDebugTelemetry(debugTempsEnabled);
                        if (!debugTempsEnabled) setFullscreenDebugOpen(false);
                        setStatus(debugTempsEnabled
                            ? "Debug ON — double-click outside the Wear button for fullscreen wheel diagnostics"
                            : "Thermal debug OFF");
                        event.stopPropagation();
                    });
                    debugTempCheckbox.addEventListener("mousedown", stopUiPropagation);
                    debugTempCheckbox.addEventListener("click", stopUiPropagation);
                    var debugSpacer = document.createElement("span");
                    debugRow.appendChild(debugLabel);
                    debugRow.appendChild(debugTempCheckbox);
                    debugRow.appendChild(debugSpacer);
                    debugGroup.appendChild(debugRow);
                    advancedContent.appendChild(debugGroup);

                    tuningGroups.forEach(function (group) {
                        var groupElement = document.createElement("section");
                        groupElement.className = "tyre-settings-group";

                        var title = document.createElement("div");
                        title.className = "tyre-settings-group-title";
                        title.textContent = group.title;
                        groupElement.appendChild(title);

                        if (group.title.indexOf("SPORT PHYSICAL STIFFNESS") >= 0) {
                            sportStiffnessStatus = document.createElement("div");
                            sportStiffnessStatus.className = "tyre-structure-tuner-status";
                            sportStiffnessStatus.textContent = "Waiting for a detected Sport tyre…";
                            sportStiffnessStatus.title = "Structural temperature → target Cα → calibrated native TreadSpring with automatic precompression compensation.";
                            groupElement.appendChild(sportStiffnessStatus);

                        }

                        if (group.title.indexOf("TYRE CONSTRUCTION JBEAM") >= 0) {
                            structureTunerStatus = document.createElement("div");
                            structureTunerStatus.className = "tyre-structure-tuner-status";
                            structureTunerStatus.textContent = "Waiting for generated tyre beams…";
                            structureTunerStatus.title = "Live Vehicle-Lua diagnostics. If APPLIED stays at 0, send a screenshot/log rather than judging the stiffness sliders by feel.";
                            groupElement.appendChild(structureTunerStatus);

                        }

                        group.settings.forEach(function (definition) {
                            var row = document.createElement("div");
                            row.className = "tyre-setting-row";
                            row.title = tuningDisplayHelp(definition);

                            var label = document.createElement("label");
                            label.className = "tyre-setting-label";
                            label.textContent = tuningDisplayLabel(definition);
                            label.htmlFor = "tyre-setting-" + definition.key;

                            var input = document.createElement("input");
                            var controlNode = input;
                            input.id = "tyre-setting-" + definition.key;
                            input.setAttribute("data-key", definition.key);
                            input.setAttribute("aria-label", tuningDisplayLabel(definition));
                            if (definition.type === "checkbox") {
                                input.className = "tyre-setting-checkbox";
                                input.type = "checkbox";
                                input.checked = Number(definition.defaultValue) >= 0.5;
                            } else if (definition.type === "range") {
                                var rangeWrap = document.createElement("div");
                                rangeWrap.className = "tyre-setting-range-wrap";
                                var rangeValue = document.createElement("span");
                                rangeValue.className = "tyre-setting-range-value";
                                input.className = "tyre-setting-range";
                                input.type = "range";
                                input.min = String(definition.displayMin === undefined ? 0 : definition.displayMin);
                                input.max = String(definition.displayMax === undefined ? 200 : definition.displayMax);
                                input.step = String(definition.displayStep === undefined ? 1 : definition.displayStep);
                                input.value = formatTuningValue(definition, definition.defaultValue);
                                rangeValue.textContent = input.value + "%";
                                input._valueLabel = rangeValue;
                                rangeWrap.appendChild(input);
                                rangeWrap.appendChild(rangeValue);
                                controlNode = rangeWrap;
                            } else {
                                input.className = "tyre-setting-input";
                                input.type = "text";
                                input.inputMode = "decimal";
                                input.value = formatTuningValue(definition, definition.defaultValue);
                                if (!usesNativePercent(definition) && !usesDirectPercent(definition)) {
                                    input.classList.add("tyre-setting-native-value");
                                    if (definition.valueUnitLabel) {
                                        var nativeUnitWrap = document.createElement("div");
                                        nativeUnitWrap.className = "tyre-setting-native-unit-wrap";
                                        var nativeUnit = document.createElement("span");
                                        nativeUnit.className = "tyre-setting-native-unit";
                                        nativeUnit.textContent = String(definition.valueUnitLabel);
                                        nativeUnitWrap.appendChild(input);
                                        nativeUnitWrap.appendChild(nativeUnit);
                                        controlNode = nativeUnitWrap;
                                    }
                                }
                                if (usesNativePercent(definition) || usesDirectPercent(definition)) {
                                    var percentWrap = document.createElement("div");
                                    percentWrap.className = "tyre-setting-percent-wrap";
                                    var percentUnit = document.createElement("span");
                                    percentUnit.className = "tyre-setting-percent-unit";
                                    percentUnit.textContent = "%";
                                    percentWrap.appendChild(input);
                                    percentWrap.appendChild(percentUnit);
                                    controlNode = percentWrap;
                                }
                            }

                            var resetButton = document.createElement("button");
                            resetButton.type = "button";
                            resetButton.className = "tyre-setting-reset";
                            resetButton.textContent = "↶";
                            resetButton.title = "Restore the current thermal preset baseline";
                            resetButton.setAttribute("aria-label", "Restore " + definition.label + " to current preset baseline");

                            if (definition.type === "checkbox") {
                                input.addEventListener("change", function (event) {
                                    var numericValue = input.checked ? 1 : 0;
                                    currentTuningValues[definition.key] = numericValue;
                                    sendTuningValue(definition.key, numericValue);
                                    if (definition.key === "sport_physical_stiffness_enabled") {
                                        updateLiveTreadPhysicalReadOnly(input.checked, null);
                                    }
                                    setStatus(input.checked
                                        ? (definition.statusOn || (definition.label + " enabled"))
                                        : (definition.statusOff || (definition.label + " disabled")));
                                    event.stopPropagation();
                                });
                                input.addEventListener("mousedown", stopUiPropagation);
                                input.addEventListener("click", stopUiPropagation);
                            } else if (definition.type === "range") {
                                input.addEventListener("input", function (event) {
                                    var displayedValue = Number(input.value);
                                    var rawValue = nativePercentToRaw(definition, displayedValue);
                                    rawValue = Math.max(definition.min, Math.min(getEffectiveDefinitionMax(definition), rawValue));
                                    currentTuningValues[definition.key] = rawValue;
                                    if (input._valueLabel) input._valueLabel.textContent = formatNumber(displayedValue) + "%";
                                    sendTuningValue(definition.key, rawValue);
                                    setStatus(definition.label + " = " + formatNumber(displayedValue) + "%");
                                    event.stopPropagation();
                                });
                                input.addEventListener("mousedown", stopUiPropagation);
                                input.addEventListener("mouseup", stopUiPropagation);
                                input.addEventListener("click", stopUiPropagation);
                                input.addEventListener("change", stopUiPropagation);
                            } else {
                                input.addEventListener("focus", function () {
                                    activeTuningInput = input;
                                    activeTuningDefinition = definition;
                                    setKeyboardCapture(true, input);
                                    setStatus("Keyboard focus requested — keypad also available");
                                });
                                input.addEventListener("mousedown", function () {
                                    activeTuningInput = input;
                                    activeTuningDefinition = definition;
                                    setKeyboardCapture(true, input);
                                });
                                input.addEventListener("keydown", function (event) {
                                    if (event.key === "Enter") {
                                        commitInput(input, definition);
                                        input.blur();
                                        event.preventDefault();
                                    } else if (event.key === "Escape") {
                                        var current = currentTuningValues[definition.key];
                                        input.value = formatTuningValue(definition, current === undefined ? definition.defaultValue : current);
                                        input.classList.remove("invalid");
                                        input.blur();
                                    }
                                    event.stopPropagation();
                                });
                                input.addEventListener("blur", function () {
                                    commitInput(input, definition);
                                });
                                input.addEventListener("mousedown", stopUiPropagation);
                                input.addEventListener("click", stopUiPropagation);
                                input.addEventListener("keyup", stopUiPropagation);
                                input.addEventListener("keypress", stopUiPropagation);
                                input.addEventListener("input", stopUiPropagation);
                            }

                            resetButton.addEventListener("click", function (event) {
                                var nativeValue = getNativeTuningValue(definition);
                                if (!isFinite(nativeValue)) nativeValue = Number(definition.defaultValue);
                                if (definition.type === "checkbox") {
                                    input.checked = Number(nativeValue) >= 0.5;
                                } else {
                                    input.value = formatTuningValue(definition, nativeValue);
                                    if (definition.type === "range" && input._valueLabel) input._valueLabel.textContent = input.value + "%";
                                    input.classList.remove("invalid");
                                }
                                currentTuningValues[definition.key] = nativeValue;
                                sendResetValue(definition.key);
                                setStatus(definition.label + " restored to native baseline");
                                event.preventDefault();
                                event.stopPropagation();
                            });

                            tuningInputs[definition.key] = input;
                            tuningResetButtons[definition.key] = resetButton;
                            tuningLabels[definition.key] = label;
                            tuningRows[definition.key] = row;
                            row.appendChild(label);
                            row.appendChild(controlNode);
                            row.appendChild(resetButton);
                            groupElement.appendChild(row);
                        });

                        advancedContent.appendChild(groupElement);
                    });
                }

                keypad.addEventListener("mousedown", function (event) {
                    event.preventDefault();
                    event.stopPropagation();
                    setKeyboardCapture(true, activeTuningInput);
                });

                keypad.addEventListener("click", function (event) {
                    var button = event.target;
                    while (button && button !== keypad && button.tagName !== "BUTTON") {
                        button = button.parentNode;
                    }
                    if (!button || button === keypad || !keypad.contains(button)) return;
                    if (!activeTuningInput) {
                        setStatus("Select a value first");
                        return;
                    }

                    var key = button.getAttribute("data-key");
                    var action = button.getAttribute("data-action");
                    if (key !== null) {
                        insertAtSelection(activeTuningInput, key);
                    } else if (action === "backspace") {
                        backspaceAtSelection(activeTuningInput);
                    } else if (action === "clear") {
                        activeTuningInput.value = "";
                        refocusInput(activeTuningInput);
                    } else if (action === "select-all") {
                        selectWholeInput(activeTuningInput);
                    } else if (action === "apply") {
                        if (typeof activeTuningInput._commitPitPsi === "function") {
                            activeTuningInput._commitPitPsi();
                        } else if (typeof activeTuningInput._commitStructuralPsi === "function") {
                            activeTuningInput._commitStructuralPsi();
                        } else {
                            commitInput(activeTuningInput, activeTuningDefinition);
                        }
                        selectWholeInput(activeTuningInput);
                    }
                    event.preventDefault();
                    event.stopPropagation();
                });

                function setPanelOpen(open) {
                    settingsPanel.hidden = !open;
                    settingsButton.setAttribute("aria-expanded", open ? "true" : "false");
                    if (open) {
                        setKeyboardCapture(true, activeTuningInput);
                        setStatus("Select a value; physical keyboard or keypad");
                    } else {
                        if (document.activeElement && settingsPanel.contains(document.activeElement)) {
                            document.activeElement.blur();
                        }
                        setKeyboardCapture(false);
                    }
                }

                settingsButton.addEventListener("click", function (event) {
                    setPanelOpen(settingsPanel.hidden);
                    event.preventDefault();
                });

                settingsClose.addEventListener("click", function (event) {
                    setPanelOpen(false);
                    event.preventDefault();
                    event.stopPropagation();
                });

                resetAllButton.addEventListener("click", function (event) {
                    tuningGroups.forEach(function (group) {
                        group.settings.forEach(function (definition) {
                            var nativeValue = getNativeTuningValue(definition);
                            if (!isFinite(nativeValue)) nativeValue = Number(definition.defaultValue);
                            currentTuningValues[definition.key] = nativeValue;
                            if (definition.type === "checkbox") {
                                tuningInputs[definition.key].checked = nativeValue >= 0.5;
                            } else {
                                tuningInputs[definition.key].value = formatTuningValue(definition, nativeValue);
                                if (definition.type === "range" && tuningInputs[definition.key]._valueLabel) tuningInputs[definition.key]._valueLabel.textContent = tuningInputs[definition.key].value + "%";
                                tuningInputs[definition.key].classList.remove("invalid");
                            }
                        });
                    });
                    sendResetAll();
                    setStatus("All values restored to preset baseline");
                    event.preventDefault();
                    event.stopPropagation();
                });

                document.addEventListener("focusin", function (event) {
                    if (!settingsPanel.hidden && settingsPanel.contains(event.target)) {
                        setKeyboardCapture(true, event.target.tagName === "INPUT" ? event.target : activeTuningInput);
                    }
                }, true);

                document.addEventListener("keydown", function (event) {
                    if (event.key !== "Escape") return;
                    if (fullscreenDebugOpen) {
                        setFullscreenDebugOpen(false);
                        setStatus("Compact tyre diagnostics ON");
                        event.preventDefault();
                        return;
                    }
                    if (!settingsPanel.hidden && (!document.activeElement || document.activeElement.tagName !== "INPUT")) {
                        setPanelOpen(false);
                    }
                });

                function pointInside(bounds, x, y) {
                    return bounds && x >= bounds.x && x <= bounds.x + bounds.width &&
                        y >= bounds.y && y <= bounds.y + bounds.height;
                }

                function canvasPoint(event) {
                    var rect = c.getBoundingClientRect();
                    return {
                        x: (event.clientX - rect.left) * (c.width / Math.max(rect.width, 1)),
                        y: (event.clientY - rect.top) * (c.height / Math.max(rect.height, 1))
                    };
                }

                function handleCanvasPrimaryClick(point) {
                    if (pointInside(wearToggleBounds, point.x, point.y)) {
                        handleWearButtonClick();
                        return true;
                    }
                    for (var i = 0; i < wheelClickBounds.length; i++) {
                        if (pointInside(wheelClickBounds[i], point.x, point.y)) {
                            setPanelOpen(true);
                            return true;
                        }
                    }
                    return false;
                }

                function clearDebugCanvasGesture() {
                    if (debugCanvasClickTimer !== null) {
                        clearTimeout(debugCanvasClickTimer);
                        debugCanvasClickTimer = null;
                    }
                    debugCanvasClickCount = 0;
                    debugCanvasFirstClickPoint = null;
                }

                function toggleDebugFromCanvasGesture() {
                    debugTempsEnabled = !debugTempsEnabled;
                    if (debugTempCheckbox) debugTempCheckbox.checked = debugTempsEnabled;
                    syncVehicleDebugTelemetry(debugTempsEnabled);

                    if (debugTempsEnabled) {
                        setStatus("Debug ON — double-click outside the Wear button for fullscreen wheel diagnostics");
                    } else {
                        setFullscreenDebugOpen(false);
                        setStatus("Thermal debug OFF");
                    }
                }

                function resolveDebugCanvasGesture() {
                    var clickCount = debugCanvasClickCount;
                    var firstPoint = debugCanvasFirstClickPoint;
                    clearDebugCanvasGesture();

                    if (clickCount === 2 && debugTempsEnabled) {
                        setFullscreenDebugOpen(!fullscreenDebugOpen);
                        setStatus(fullscreenDebugOpen
                            ? "Fullscreen tyre diagnostics ON — double-click outside the Wear button or press Esc to close"
                            : "Compact tyre diagnostics ON");
                        return;
                    }

                    if (firstPoint) handleCanvasPrimaryClick(firstPoint);
                }

                c.addEventListener("click", function (event) {
                    var point = canvasPoint(event);

                    if (pointInside(wearToggleBounds, point.x, point.y)) {
                        clearDebugCanvasGesture();
                        handleWearButtonClick();
                        event.preventDefault();
                        event.stopPropagation();
                        return;
                    }

                    if (debugCanvasClickCount === 0) {
                        debugCanvasClickCount = 1;
                        debugCanvasFirstClickPoint = point;
                        debugCanvasClickTimer = setTimeout(
                            resolveDebugCanvasGesture,
                            debugCanvasClickWindowMs
                        );
                    } else if (debugCanvasClickCount === 1) {
                        clearTimeout(debugCanvasClickTimer);
                        debugCanvasClickCount = 2;
                        debugCanvasClickTimer = setTimeout(
                            resolveDebugCanvasGesture,
                            debugCanvasTripleGraceMs
                        );
                    } else {
                        clearDebugCanvasGesture();
                        toggleDebugFromCanvasGesture();
                    }

                    event.preventDefault();
                    event.stopPropagation();
                });

                c.addEventListener("mousemove", function (event) {
                    var point = canvasPoint(event);
                    var hoveringWheel = false;
                    for (var i = 0; i < wheelClickBounds.length; i++) {
                        if (pointInside(wheelClickBounds[i], point.x, point.y)) {
                            hoveringWheel = true;
                            break;
                        }
                    }
                    c.style.cursor = (pointInside(wearToggleBounds, point.x, point.y) || hoveringWheel) ? "pointer" : "default";
                });

                c.addEventListener("mouseleave", function () {
                    c.style.cursor = "default";
                });

                function roundRect(context, x, y, width, height, radius, fill, stroke) {
                    if (typeof radius === "number") {
                        radius = { tl: radius, tr: radius, br: radius, bl: radius };
                    } else {
                        radius = radius || { tl: 0, tr: 0, br: 0, bl: 0 };
                    }
                    context.beginPath();
                    context.moveTo(x + radius.tl, y);
                    context.lineTo(x + width - radius.tr, y);
                    context.quadraticCurveTo(x + width, y, x + width, y + radius.tr);
                    context.lineTo(x + width, y + height - radius.br);
                    context.quadraticCurveTo(x + width, y + height, x + width - radius.br, y + height);
                    context.lineTo(x + radius.bl, y + height);
                    context.quadraticCurveTo(x, y + height, x, y + height - radius.bl);
                    context.lineTo(x, y + radius.tl);
                    context.quadraticCurveTo(x, y, x + radius.tl, y);
                    context.closePath();
                    if (fill) context.fill();
                    if (stroke !== false) context.stroke();
                }

                function drawWearToggle(enabled, paused) {
                    var minDimension = Math.max(1, Math.min(c.width, c.height));
                    var buttonHeight = Math.max(8, Math.min(20, minDimension * 0.11));
                    var fullLabel = c.width >= 90 && c.height >= 65;
                    var buttonWidth = fullLabel ? buttonHeight * 3.2 : Math.max(12, buttonHeight * 1.45);
                    var margin = Math.max(2, buttonHeight * 0.18);
                    var topBand = buttonHeight + Math.max(2, buttonHeight * 0.16);
                    var x = Math.max(0, c.width * 0.5 - buttonWidth * 0.5);
                    var y = Math.max(1, topBand - buttonHeight);

                    wearToggleBounds = { x: x, y: y, width: buttonWidth, height: buttonHeight };

                    ctx.save();
                    ctx.lineWidth = Math.max(1, buttonHeight * 0.09);
                    if (paused) {
                        ctx.fillStyle = "rgba(82,82,82,0.92)";
                        ctx.strokeStyle = "rgba(190,190,190,0.95)";
                    } else if (enabled) {
                        ctx.fillStyle = "rgba(22,105,62,0.88)";
                        ctx.strokeStyle = "rgba(115,255,173,0.95)";
                    } else {
                        ctx.fillStyle = "rgba(128,30,35,0.90)";
                        ctx.strokeStyle = "rgba(255,135,135,0.98)";
                    }
                    roundRect(ctx, x, y, buttonWidth, buttonHeight, buttonHeight * 0.28, true, true);
                    ctx.fillStyle = "rgba(255,255,255,1)";
                    ctx.textAlign = "center";
                    ctx.textBaseline = "middle";
                    ctx.font = "bold " + Math.max(5, buttonHeight * 0.43) + "pt Arial, sans-serif";
                    ctx.shadowColor = "rgba(0,0,0,0.8)";
                    ctx.shadowBlur = 2;
                    ctx.shadowOffsetX = 0;
                    ctx.shadowOffsetY = 1;
                    var label = paused ? "OFF" : (enabled ? "WEAR ON" : "WEAR OFF");
                    ctx.fillText(fullLabel ? label : (paused ? "OFF" : "W"), x + buttonWidth / 2, y + buttonHeight / 2);
                    ctx.restore();

                    if (debugTempsEnabled) {
                        c.title = paused
                            ? "Tyre thermals OFF — single-click the Wear button to resume · double-click outside it for fullscreen · triple-click outside it for Debug OFF"
                            : (enabled ? "Tyre wear enabled" : "Tyre wear disabled") +
                                " — the Wear button keeps its own single/double-click controls · double-click outside it for fullscreen · triple-click outside it for Debug OFF";
                    } else if (paused) {
                        c.title = "Tyre thermals OFF — tyres held at peak-grip temperature; single-click the Wear button to resume · triple-click outside it for Debug ON";
                    } else {
                        c.title = enabled
                            ? "Tyre wear enabled — single-click to disable wear; double-click the Wear button for thermal OFF · triple-click outside it for Debug ON"
                            : "Tyre wear disabled — single-click to enable wear; double-click the Wear button for thermal OFF · triple-click outside it for Debug ON";
                    }
                }

                function drawWaitingState() {
                    ctx.setTransform(1, 0, 0, 1, 0, 0);
                    ctx.clearRect(0, 0, c.width, c.height);
                    wheelClickBounds = [];
                    ctx.save();
                    ctx.textAlign = "center";
                    ctx.textBaseline = "middle";
                    ctx.fillStyle = "rgba(255,255,255,0.78)";
                    ctx.shadowColor = "rgba(0,0,0,0.82)";
                    ctx.shadowBlur = 3;
                    ctx.shadowOffsetX = 0;
                    ctx.shadowOffsetY = 1;
                    var small = c.width < 80 || c.height < 55;
                    ctx.font = "bold " + Math.max(7, Math.min(15, Math.min(c.width, c.height) * 0.09)) + "pt Arial, sans-serif";
                    ctx.fillText(small ? "T" : "TYRES", c.width * 0.5, c.height * 0.45);
                    if (!small) {
                        ctx.fillStyle = "rgba(255,255,255,0.48)";
                        ctx.font = Math.max(6, Math.min(10, Math.min(c.width, c.height) * 0.055)) + "pt Arial, sans-serif";
                        ctx.fillText("waiting for vehicle data", c.width * 0.5, c.height * 0.57);
                    }
                    ctx.restore();
                    drawWearToggle(wearEnabled, thermalsPaused);
                }

                function drawWheelData(name, temps, workingTemp, condition, camber, tyreNumber, wheelCount, livePressurePsi, referencePressurePsi, hotEstimatePressurePsi, airTemp, loadBias, treadAvgTemp, flashTemp, coreTemp, patchHotFraction, patchEffectiveTemp, hotspotContact, patchGripMultiplier, brushSlidingLengthFraction, nativeDryPatchRatio, flashThermalModifier, kinematicSlipAngleDeg, brushCriticalAngleDeg, treadNominalDepthMm, treadRemainingDepthMm, treadReserveDepthMm, treadWearableRemainingMm, treadOuterDepthMm, treadMiddleDepthMm, treadInnerDepthMm, treadFieldOuter, treadFieldMiddle, treadFieldInner, sidewallOuterTemp, sidewallInnerTemp, rimTemp, circumferentialLocalL1DeltaC, circumferentialLocalL2DeltaC, circumferentialLocalL3DeltaC, circumferentialLocalL4DeltaC) {
                    temps = temps && temps.length ? temps : [0, 0, 0, 0];
                    condition = condition === undefined ? 100 : condition;
                    name = name || "";

                    function clamp01(value) { return Math.max(0, Math.min(1, value)); }
                    function mixColor(a, b, t) {
                        t = clamp01(t);
                        return {
                            r: a.r + (b.r - a.r) * t,
                            g: a.g + (b.g - a.g) * t,
                            b: a.b + (b.b - a.b) * t,
                            a: a.a + (b.a - a.a) * t
                        };
                    }
                    function colorToRgbaString(color) {
                        return "rgba(" + Math.round(color.r) + "," + Math.round(color.g) + "," +
                            Math.round(color.b) + "," + clamp01(color.a).toFixed(3) + ")";
                    }
                    function tyreTemperatureColor(temperature, targetTemperature) {
                        return fullscreenTemperatureColor(temperature, targetTemperature);
                    }
                    function finiteOr(value, fallback) {
                        value = Number(value);
                        return isFinite(value) ? value : fallback;
                    }

                    var conditionClamped = Math.max(0, Math.min(100, Number(condition) || 0));
                    var nominalDepthMmValue = Math.max(0, Number(treadNominalDepthMm) || 0);
                    var reserveDepthMmValue = Math.max(0, Number(treadReserveDepthMm) || 0);
                    var remainingDepthMmValue = Math.max(0, Number(treadRemainingDepthMm) || 0);
                    var zoneRemainingDepthMm = [
                        Math.max(0, Number(treadOuterDepthMm) || remainingDepthMmValue),
                        Math.max(0, Number(treadMiddleDepthMm) || remainingDepthMmValue),
                        Math.max(0, Number(treadInnerDepthMm) || remainingDepthMmValue)
                    ];
                    var zoneTreadField = [
                        (treadFieldOuter && treadFieldOuter.length) ? treadFieldOuter : null,
                        (treadFieldMiddle && treadFieldMiddle.length) ? treadFieldMiddle : null,
                        (treadFieldInner && treadFieldInner.length) ? treadFieldInner : null
                    ];

                    ctx.textAlign = "center";
                    var right = 0;
                    var back = Math.floor(tyreNumber / 2);
                    var minDimension = Math.max(1, Math.min(c.width, c.height));
                    var buttonHeightSlot = Math.max(8, Math.min(20, minDimension * 0.11));
                    var topBand = buttonHeightSlot + Math.max(4, buttonHeightSlot * 0.40);
                    var w = Math.min(c.width * 0.318, c.height * 0.248);
                    var h = w * 1.50;

                    var canonicalWheelName = normalizeFullscreenWheelName(name);
                    if (canonicalWheelName) {
                        right = (canonicalWheelName === "FR" || canonicalWheelName === "RR") ? 1 : 0;
                        back = (canonicalWheelName === "RL" || canonicalWheelName === "RR") ? 1 : 0;
                    } else {
                        if (tyreNumber % 2 === 1) right = 1;
                        if (name[name.length - 1] === "R") right = 1;
                        else if (name[name.length - 1] === "L") right = 0;
                        if (name === "RR2") right = 1;
                        else if (name === "RL2") right = 0;
                        if (name === "RL2" || name === "RR2") back = 2;
                    }

                    var colGap = Math.max(2.4, w * 0.055);
                    var rowGap = Math.max(7.0, h * 0.135);
                    var groupWidth = w * 2 + colGap;
                    var x = (c.width - groupWidth) * 0.5 + right * (w + colGap);
                    var y = topBand + back * (h + rowGap);
                    var tyreX = x + 1;
                    var tyreY = y;
                    var tyreW = w - 2;
                    var tyreH = h * 0.985;
                    var cx = tyreX + tyreW * 0.5;
                    wheelClickBounds[tyreNumber] = { x: tyreX, y: tyreY, width: tyreW, height: tyreH };

                    var patchHot = clamp01(Number(patchHotFraction) || 0);
                    var patchTemp = finiteOr(patchEffectiveTemp, finiteOr(treadAvgTemp, Number(workingTemp) || 0));
                    var hotspotPulse = clamp01(Number(hotspotContact) || 0);
                    var patchGripLoss = clamp01(1 - (Number(patchGripMultiplier) || 1));
                    var heatAboveWorking = Math.max(0, patchTemp - (Number(workingTemp) || patchTemp));
                    var thermalHeatSeverity = clamp01(heatAboveWorking / 80);
                    var outlineHeat = clamp01(thermalHeatSeverity * (0.30 + 0.70 * patchHot)
                        + patchGripLoss * 0.75 + hotspotPulse * 0.95);
                    var outlineBase = { r: 255, g: 255, b: 255, a: 0.86 };
                    var outlineWarm = { r: 255, g: 150, b: 55, a: 0.96 };
                    var outlineHot = { r: 255, g: 45, b: 35, a: 1.0 };
                    var outlineColor = outlineHeat < 0.45
                        ? colorToRgbaString(mixColor(outlineBase, outlineWarm, outlineHeat / 0.45))
                        : colorToRgbaString(mixColor(outlineWarm, outlineHot, (outlineHeat - 0.45) / 0.55));
                    var borderWidth = Math.max(1, Math.min(1.65, w * 0.02));

                    var bulkTreadValue = Number(treadAvgTemp);
                    if (!isFinite(bulkTreadValue)) {
                        var sum = 0, count = 0;
                        for (var bt = 0; bt < 3; bt++) {
                            var tv = Number(temps[bt]);
                            if (isFinite(tv)) { sum += tv; count++; }
                        }
                        bulkTreadValue = count ? sum / count : (Number(workingTemp) || 0);
                    }
                    var coreTemperatureValue = finiteOr(coreTemp, finiteOr(temps[3], bulkTreadValue));
                    var sideOuterValue = finiteOr(sidewallOuterTemp, coreTemperatureValue);
                    var sideInnerValue = finiteOr(sidewallInnerTemp, coreTemperatureValue);
                    var rimTemperatureValue = finiteOr(rimTemp, finiteOr(airTemp, coreTemperatureValue));

                    var pressureValue = finiteOr(livePressurePsi, 0);
                    var tunePressureValue = finiteOr(referencePressurePsi, pressureValue);
                    var hotPressureValue = finiteOr(hotEstimatePressurePsi, tunePressureValue + 2);
                    if (hotPressureValue <= tunePressureValue) hotPressureValue = tunePressureValue + 2;

                    function pressureIndicatorColor(livePsi, coldPsi, hotPsi) {
                        var deepBlue = { r: 20, g: 55, b: 180, a: 1.0 };
                        var coolBlue = { r: 85, g: 220, b: 255, a: 0.96 };
                        var coldTuneBlue = mixColor(deepBlue, coolBlue, 0.55);
                        var working = { r: 185, g: 190, b: 195, a: 0.06 };
                        var yellow = { r: 198, g: 159, b: 16, a: 1.0 };
                        var red = { r: 255, g: 62, b: 42, a: 1.0 };
                        coldPsi = finiteOr(coldPsi, livePsi);
                        hotPsi = finiteOr(hotPsi, coldPsi + 2);
                        livePsi = finiteOr(livePsi, coldPsi);
                        if (hotPsi <= coldPsi) hotPsi = coldPsi + 2;
                        var deepBluePsi = Math.max(0, coldPsi - 4);
                        if (livePsi <= deepBluePsi) return colorToRgbaString(deepBlue);
                        if (livePsi < coldPsi) return colorToRgbaString(mixColor(deepBlue, coldTuneBlue,
                            (livePsi - deepBluePsi) / Math.max(0.1, coldPsi - deepBluePsi)));
                        if (livePsi < hotPsi) return colorToRgbaString(mixColor(coldTuneBlue, working,
                            (livePsi - coldPsi) / Math.max(0.1, hotPsi - coldPsi)));
                        var redPsi = 50;
                        if (hotPsi >= redPsi) return livePsi >= redPsi ? colorToRgbaString(red) : colorToRgbaString(working);
                        var yellowPsi = hotPsi + (redPsi - hotPsi) * 0.50;
                        if (livePsi < yellowPsi) return colorToRgbaString(mixColor(working, yellow,
                            (livePsi - hotPsi) / Math.max(0.1, yellowPsi - hotPsi)));
                        if (livePsi < redPsi) return colorToRgbaString(mixColor(yellow, red,
                            (livePsi - yellowPsi) / Math.max(0.1, redPsi - yellowPsi)));
                        return colorToRgbaString(red);
                    }

                    function healthTextColor(health) {
                        if (health >= 75) return "rgba(255,255,255,0.97)";
                        if (health >= 50) return "rgba(255,225,95,0.98)";
                        if (health >= 25) return "rgba(255,154,55,0.99)";
                        return "rgba(255,68,55,1)";
                    }

                    var healthH = Math.max(8.2, tyreH * 0.115);
                    var rimH = Math.max(9.5, tyreH * 0.145);
                    var sideBandH = Math.max(8.0, tyreH * 0.115);
                    var tempTextH = Math.max(6.0, tyreH * 0.080);
                    var healthY = tyreY + healthH * 0.46;
                    var rimTopY = tyreY + healthH + 0.3;
                    var rimBottomY = rimTopY + rimH;
                    var sideBandTopY = rimBottomY + Math.max(1.0, borderWidth * 0.65);
                    var treadTopY = sideBandTopY + sideBandH;
                    var treadBottomY = tyreY + tyreH - tempTextH;
                    var treadH = Math.max(18, treadBottomY - treadTopY);

                    var treadGroupW = tyreW * 0.94;
                    var treadGroupX = cx - treadGroupW * 0.5;
                    var treadGap = 0;
                    var middleW = treadGroupW * 0.36;
                    var shoulderW = Math.max(3, (treadGroupW - middleW - treadGap * 2) * 0.5);
                    var sectionX = [
                        treadGroupX,
                        treadGroupX + shoulderW + treadGap,
                        treadGroupX + shoulderW + treadGap + middleW + treadGap
                    ];
                    var sectionW = [shoulderW, middleW, shoulderW];
                    var sectionCenter = [
                        sectionX[0] + sectionW[0] * 0.5,
                        sectionX[1] + sectionW[1] * 0.5,
                        sectionX[2] + sectionW[2] * 0.5
                    ];

                    ctx.save();
                    ctx.textAlign = "center";
                    ctx.textBaseline = "middle";
                    ctx.fillStyle = healthTextColor(conditionClamped);
                    ctx.font = 'bold ' + Math.max(5.5, Math.min(healthH * 0.56, tyreW * 0.13)) + 'pt "Lucida Console", Monaco, monospace';
                    ctx.shadowColor = "rgba(0,0,0,0.90)";
                    ctx.shadowBlur = 2.2;
                    var healthText = conditionClamped >= 99.95
                        ? "100%"
                        : Math.max(0, conditionClamped).toFixed(1) + "%";
                    ctx.fillText(healthText, cx, healthY);
                    ctx.restore();

                    var psiW = Math.max(16, middleW * 1.18);
                    var psiH = Math.max(7, sideBandH * 0.80);
                    var psiX = cx - psiW * 0.5;
                    var psiY = sideBandTopY + (sideBandH - psiH) * 0.42;

                    var rimStrokeW = Math.max(4.05, tyreW * 0.102); // 1.5x old 0.068*tyreW
                    var sideBlockW = rimStrokeW;
                    var leftSideX = sectionX[0];
                    var rightSideX = sectionX[2] + sectionW[2] - sideBlockW;

                    var rimOuterLeft = leftSideX;
                    var rimOuterRight = rightSideX + sideBlockW;
                    var rimTotalLegSpan = Math.max(4.0, treadTopY - rimTopY);
                    var rimLegLen = Math.max(2.4, rimTotalLegSpan * 0.30);
                    var rimLowerY = rimTopY + rimLegLen;
                    var rimCorner = Math.max(2.8, tyreW * 0.072);
                    var rimInnerLeft = rimOuterLeft + rimStrokeW;
                    var rimInnerRight = rimOuterRight - rimStrokeW;
                    var rimInnerTopY = rimTopY + rimStrokeW;
                    var rimInnerCorner = Math.max(0.8, rimCorner - rimStrokeW * 0.45);
                    function traceRimOuterEdge() {
                        ctx.beginPath();
                        ctx.moveTo(rimOuterLeft, rimLowerY);
                        ctx.lineTo(rimOuterLeft, rimTopY + rimCorner);
                        ctx.quadraticCurveTo(rimOuterLeft, rimTopY, rimOuterLeft + rimCorner, rimTopY);
                        ctx.lineTo(rimOuterRight - rimCorner, rimTopY);
                        ctx.quadraticCurveTo(rimOuterRight, rimTopY, rimOuterRight, rimTopY + rimCorner);
                        ctx.lineTo(rimOuterRight, rimLowerY);
                    }
                    function traceRimInnerEdge() {
                        ctx.beginPath();
                        ctx.moveTo(rimInnerLeft, rimLowerY);
                        ctx.lineTo(rimInnerLeft, rimInnerTopY + rimInnerCorner);
                        ctx.quadraticCurveTo(rimInnerLeft, rimInnerTopY, rimInnerLeft + rimInnerCorner, rimInnerTopY);
                        ctx.lineTo(rimInnerRight - rimInnerCorner, rimInnerTopY);
                        ctx.quadraticCurveTo(rimInnerRight, rimInnerTopY, rimInnerRight, rimInnerTopY + rimInnerCorner);
                        ctx.lineTo(rimInnerRight, rimLowerY);
                    }
                    function fillRimBand() {
                        ctx.beginPath();
                        ctx.moveTo(rimOuterLeft, rimLowerY);
                        ctx.lineTo(rimOuterLeft, rimTopY + rimCorner);
                        ctx.quadraticCurveTo(rimOuterLeft, rimTopY, rimOuterLeft + rimCorner, rimTopY);
                        ctx.lineTo(rimOuterRight - rimCorner, rimTopY);
                        ctx.quadraticCurveTo(rimOuterRight, rimTopY, rimOuterRight, rimTopY + rimCorner);
                        ctx.lineTo(rimOuterRight, rimLowerY);
                        ctx.lineTo(rimInnerRight, rimLowerY);
                        ctx.lineTo(rimInnerRight, rimInnerTopY + rimInnerCorner);
                        ctx.quadraticCurveTo(rimInnerRight, rimInnerTopY, rimInnerRight - rimInnerCorner, rimInnerTopY);
                        ctx.lineTo(rimInnerLeft + rimInnerCorner, rimInnerTopY);
                        ctx.quadraticCurveTo(rimInnerLeft, rimInnerTopY, rimInnerLeft, rimInnerTopY + rimInnerCorner);
                        ctx.lineTo(rimInnerLeft, rimLowerY);
                        ctx.closePath();
                    }
                    ctx.save();
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.fillStyle = tyreTemperatureColor(rimTemperatureValue, workingTemp);
                    ctx.globalAlpha = 0.96;
                    fillRimBand(); ctx.fill();
                    ctx.globalAlpha = 1;
                    ctx.strokeStyle = "rgba(255,255,255,0.92)";
                    ctx.lineWidth = Math.max(0.70, borderWidth * 0.72);
                    traceRimOuterEdge(); ctx.stroke();
                    traceRimInnerEdge(); ctx.stroke();
                    ctx.restore();

                    var originalSideBottomY = treadTopY - Math.max(1.8, borderWidth * 1.15);
                    var originalSideBlockH = Math.max(2.8, originalSideBottomY - rimLowerY);
                    var sideBlockH = Math.max(2.4, originalSideBlockH * 0.80);
                    var sideBlockBottomY = treadTopY;
                    var sideBlockTopY = sideBlockBottomY - sideBlockH;
                    var sideBlockRadius = 0;

                    var rimLegExtensionH = Math.max(0, sideBlockTopY - rimLowerY);
                    function drawRimLegExtension(x) {
                        if (rimLegExtensionH <= 0.05) return;
                        ctx.save();
                        ctx.fillStyle = tyreTemperatureColor(rimTemperatureValue, workingTemp);
                        ctx.globalAlpha = 0.96;
                        ctx.fillRect(x, rimLowerY, sideBlockW, rimLegExtensionH);
                        ctx.globalAlpha = 1;
                        ctx.strokeStyle = "rgba(255,255,255,0.92)";
                        ctx.lineWidth = Math.max(0.70, borderWidth * 0.72);
                        ctx.beginPath();
                        ctx.moveTo(x, rimLowerY);
                        ctx.lineTo(x, sideBlockTopY);
                        ctx.moveTo(x + sideBlockW, rimLowerY);
                        ctx.lineTo(x + sideBlockW, sideBlockTopY);
                        ctx.stroke();
                        ctx.restore();
                    }
                    drawRimLegExtension(leftSideX);
                    drawRimLegExtension(rightSideX);

                    function drawSidewallColumn(x, temperature) {
                        var fill = tyreTemperatureColor(temperature, workingTemp);
                        ctx.save();
                        ctx.fillStyle = fill;
                        ctx.globalAlpha = 0.88;
                        roundRect(ctx, x, sideBlockTopY, sideBlockW, sideBlockH, sideBlockRadius, true, false);
                        ctx.globalAlpha = 1;
                        ctx.strokeStyle = "rgba(255,255,255,0.92)";
                        ctx.lineWidth = Math.max(0.70, borderWidth * 0.72);
                        roundRect(ctx, x, sideBlockTopY, sideBlockW, sideBlockH, sideBlockRadius, false, true);
                        ctx.restore();
                    }
                    drawSidewallColumn(leftSideX, sideOuterValue);
                    drawSidewallColumn(rightSideX, sideInnerValue);

                    var psiFill = pressureIndicatorColor(pressureValue, tunePressureValue, hotPressureValue);
                    var cavityX = leftSideX + sideBlockW;
                    var cavityY = rimLowerY;
                    var cavityW = Math.max(4, rightSideX - cavityX);
                    var cavityBottomY = treadTopY;
                    var cavityH = Math.max(3, cavityBottomY - cavityY);
                    var coreBoxH = Math.max(3.0, cavityH / 3.0);
                    var coreBoxY = cavityBottomY - coreBoxH;
                    var airBoxH = Math.max(2.0, coreBoxY - cavityY);

                    ctx.save();
                    ctx.fillStyle = psiFill;
                    ctx.globalAlpha = 0.72;
                    ctx.fillRect(cavityX, cavityY, cavityW, airBoxH);
                    ctx.globalAlpha = 1;
                    ctx.textAlign = "center";
                    ctx.textBaseline = "middle";
                    ctx.fillStyle = "rgba(255,255,255,0.98)";
                    var psiFont = Math.max(4.2, Math.min(airBoxH * 0.40, cavityW * 0.18));
                    ctx.font = 'bold ' + psiFont + 'pt "Lucida Console", Monaco, monospace';
                    ctx.shadowColor = "rgba(0,0,0,0.90)";
                    ctx.shadowBlur = 2;
                    ctx.fillText(pressureValue.toFixed(1), cx, cavityY + airBoxH * 0.50);
                    ctx.restore();

                    ctx.save();
                    ctx.fillStyle = tyreTemperatureColor(coreTemperatureValue, workingTemp);
                    ctx.globalAlpha = 0.88;
                    ctx.fillRect(cavityX, coreBoxY, cavityW, coreBoxH);
                    ctx.globalAlpha = 1;
                    ctx.strokeStyle = "rgba(255,255,255,0.92)";
                    ctx.lineWidth = Math.max(0.70, borderWidth * 0.72);
                    ctx.strokeRect(cavityX, coreBoxY, cavityW, coreBoxH);
                    ctx.textAlign = "center";
                    ctx.textBaseline = "middle";
                    ctx.fillStyle = "rgba(255,255,255,0.98)";
                    var coreFont = Math.max(3.9, Math.min(coreBoxH * 0.48, cavityW * 0.17));
                    ctx.font = 'bold ' + coreFont + 'pt "Lucida Console", Monaco, monospace';
                    ctx.shadowColor = "rgba(0,0,0,0.92)";
                    ctx.shadowBlur = 2;
                    ctx.fillText(Math.round(coreTemperatureValue), cx, coreBoxY + coreBoxH * 0.52);
                    ctx.restore();

                    var zoneRemainingScaleBySection = [1, 1, 1];
                    var treadBeltScale = 0;
                    for (var zs = 0; zs < 3; zs++) {
                        if (nominalDepthMmValue > 1e-6) {
                            zoneRemainingScaleBySection[zs] = Math.max(0, Math.min(1,
                                zoneRemainingDepthMm[zs] / nominalDepthMmValue));
                            treadBeltScale = Math.max(0, Math.min(1, reserveDepthMmValue / nominalDepthMmValue));
                        } else {
                            zoneRemainingScaleBySection[zs] = Math.max(0, Math.min(1, conditionClamped / 100));
                            treadBeltScale = 0.05;
                        }
                    }
                    var zoneEdgeScale = [
                        zoneRemainingScaleBySection[0],
                        (zoneRemainingScaleBySection[0] + zoneRemainingScaleBySection[1]) * 0.5,
                        (zoneRemainingScaleBySection[1] + zoneRemainingScaleBySection[2]) * 0.5,
                        zoneRemainingScaleBySection[2]
                    ];

                    function fieldTemperature(zone, row) {
                        var field = zoneTreadField[zone];
                        if (field && field.length) {
                            var idx = Math.max(0, Math.min(field.length - 1,
                                field.length - 1 - Math.round(row * (field.length - 1) / 11)));
                            var fv = Number(field[idx]);
                            if (isFinite(fv)) return fv;
                        }
                        var t = row / 11;
                        var surface = finiteOr(temps[zone], bulkTreadValue);
                        var deep = coreTemperatureValue * 0.68 + bulkTreadValue * 0.32;
                        return deep + (surface - deep) * t;
                    }

                    for (var bg = 0; bg < 3; bg++) {
                        var bgRadius = Math.max(1.7, sectionW[bg] * 0.20);
                        ctx.save();
                        ctx.fillStyle = "rgba(0,0,0,0.30)";
                        roundRect(ctx, sectionX[bg], treadTopY, sectionW[bg], treadH,
                            { tl: bgRadius, tr: bgRadius, br: bgRadius, bl: bgRadius }, true, false);
                        ctx.restore();
                    }

                    var gradientLeftX = sectionX[0];
                    var gradientRightX = sectionX[2] + sectionW[2];
                    var gradientSpan = Math.max(1, gradientRightX - gradientLeftX);
                    var middleLeftStop = clamp01((sectionX[1] - gradientLeftX) / gradientSpan);
                    var middleRightStop = clamp01((sectionX[1] + sectionW[1] - gradientLeftX) / gradientSpan);
                    var shoulderPeakFraction = 2 / 3;
                    var leftPeakStop = clamp01((sectionX[0] + sectionW[0] * shoulderPeakFraction - gradientLeftX) / gradientSpan);
                    var rightPeakStop = clamp01((sectionX[2] + sectionW[2] * shoulderPeakFraction - gradientLeftX) / gradientSpan);

                    function traceTreadZoneShape(zx, zw, leftBottom, centerBottom, rightBottom, zoneIndex, radius) {
                        radius = Math.max(0, radius || 0);
                        ctx.beginPath();
                        ctx.moveTo(zx, treadTopY);
                        ctx.lineTo(zx + zw, treadTopY);
                        if (zoneIndex === 0) {
                            ctx.lineTo(zx + zw, rightBottom);
                            ctx.lineTo(zx + zw * 0.5, centerBottom);
                            ctx.lineTo(zx + radius, leftBottom);
                            ctx.quadraticCurveTo(zx, leftBottom, zx, Math.max(treadTopY, leftBottom - radius));
                        } else if (zoneIndex === 2) {
                            ctx.lineTo(zx + zw, Math.max(treadTopY, rightBottom - radius));
                            ctx.quadraticCurveTo(zx + zw, rightBottom, zx + zw - radius, rightBottom);
                            ctx.lineTo(zx + zw * 0.5, centerBottom);
                            ctx.lineTo(zx, leftBottom);
                        } else {
                            ctx.lineTo(zx + zw, rightBottom);
                            ctx.lineTo(zx + zw * 0.5, centerBottom);
                            ctx.lineTo(zx, leftBottom);
                        }
                        ctx.closePath();
                    }

                    function interpolateFieldTemp(zoneIndex, position) {
                        position = Math.max(0, Math.min(11, position));
                        var base = Math.floor(position);
                        var next = Math.min(11, base + 1);
                        var frac = position - base;
                        var a = fieldTemperature(zoneIndex, base);
                        var b = fieldTemperature(zoneIndex, next);
                        return a + (b - a) * frac;
                    }

                    function continuousFieldTemperature(zoneIndex, normalizedDepth) {
                        normalizedDepth = clamp01(normalizedDepth);
                        var position = normalizedDepth * 11;
                        var base = Math.floor(position);
                        var next = Math.min(11, base + 1);
                        var frac = position - base;
                        var a = fieldTemperature(zoneIndex, base);
                        var b = fieldTemperature(zoneIndex, next);
                        var bulkInterpolated = a + (b - a) * frac;
                        return bulkInterpolated + hotspotDeltaForPosition(position);
                    }

                    var zoneRenderGeometry = [];
                    var maxLiveWearH = 0;
                    for (var zg = 0; zg < 3; zg++) {
                        var zgLeftScale = zoneEdgeScale[zg];
                        var zgCenterScale = zoneRemainingScaleBySection[zg];
                        var zgRightScale = zoneEdgeScale[zg + 1];
                        var zgLeftBottom = treadTopY + treadH * zgLeftScale;
                        var zgCenterBottom = treadTopY + treadH * zgCenterScale;
                        var zgRightBottom = treadTopY + treadH * zgRightScale;
                        var zgLeftWearH = Math.max(0, zgLeftBottom - treadTopY);
                        var zgCenterWearH = Math.max(0, zgCenterBottom - treadTopY);
                        var zgRightWearH = Math.max(0, zgRightBottom - treadTopY);
                        var zgAverageWearH = Math.max(0.5, (zgLeftWearH + zgCenterWearH + zgRightWearH) / 3);
                        var zgCornerRadius = Math.max(0, Math.min(Math.max(2.8, tyreW * 0.072), sectionW[zg] * 0.45, treadH * 0.18));
                        maxLiveWearH = Math.max(maxLiveWearH, zgLeftWearH, zgCenterWearH, zgRightWearH);
                        zoneRenderGeometry.push({
                            zx: sectionX[zg], zw: sectionW[zg],
                            leftBottom: zgLeftBottom, centerBottom: zgCenterBottom, rightBottom: zgRightBottom,
                            leftWearH: zgLeftWearH, centerWearH: zgCenterWearH, rightWearH: zgRightWearH,
                            averageWearH: zgAverageWearH, cornerRadius: zgCornerRadius
                        });
                    }

                    var hotspotLayerDeltas = [
                        finiteOr(circumferentialLocalL1DeltaC, 0),
                        finiteOr(circumferentialLocalL2DeltaC, 0),
                        finiteOr(circumferentialLocalL3DeltaC, 0),
                        finiteOr(circumferentialLocalL4DeltaC, 0)
                    ];
                    var hotspotCellDeltas = [
                        hotspotLayerDeltas[0],
                        hotspotLayerDeltas[1], hotspotLayerDeltas[1],
                        hotspotLayerDeltas[2], hotspotLayerDeltas[2], hotspotLayerDeltas[2],
                        hotspotLayerDeltas[3], hotspotLayerDeltas[3], hotspotLayerDeltas[3], hotspotLayerDeltas[3],
                        0, 0
                    ];
                    function hotspotDeltaForPosition(position) {
                        position = Math.max(0, Math.min(11, position));
                        var runtimePosition = 11 - position;
                        var base = Math.floor(runtimePosition);
                        var next = Math.min(11, base + 1);
                        var frac = runtimePosition - base;
                        var a = hotspotCellDeltas[base] || 0;
                        var b = hotspotCellDeltas[next] || 0;
                        return a + (b - a) * frac;
                    }

                    for (var zone = 0; zone < 3; zone++) {
                        var geom = zoneRenderGeometry[zone];
                        ctx.save();
                        traceTreadZoneShape(geom.zx, geom.zw, geom.leftBottom, geom.centerBottom, geom.rightBottom, zone, geom.cornerRadius);
                        ctx.clip();

                        var firstPixelY = Math.floor(treadTopY);
                        var lastPixelY = Math.ceil(treadTopY + maxLiveWearH);
                        for (var pixelY = firstPixelY; pixelY < lastPixelY; pixelY++) {
                            var sampleY = pixelY + 0.5;
                            var outerDepth = clamp01((sampleY - treadTopY) / Math.max(0.5, zoneRenderGeometry[0].averageWearH));
                            var middleDepth = clamp01((sampleY - treadTopY) / Math.max(0.5, zoneRenderGeometry[1].averageWearH));
                            var innerDepth = clamp01((sampleY - treadTopY) / Math.max(0.5, zoneRenderGeometry[2].averageWearH));
                            var outerTempAtY = continuousFieldTemperature(0, outerDepth);
                            var middleTempAtY = continuousFieldTemperature(1, middleDepth);
                            var innerTempAtY = continuousFieldTemperature(2, innerDepth);

                            var lateralGradient = ctx.createLinearGradient(gradientLeftX, 0, gradientRightX, 0);
                            var outerColorAtY = tyreTemperatureColor(outerTempAtY, workingTemp);
                            var middleColorAtY = tyreTemperatureColor(middleTempAtY, workingTemp);
                            var innerColorAtY = tyreTemperatureColor(innerTempAtY, workingTemp);
                            lateralGradient.addColorStop(0.00, outerColorAtY);
                            lateralGradient.addColorStop(leftPeakStop, outerColorAtY);
                            lateralGradient.addColorStop(middleLeftStop, middleColorAtY);
                            lateralGradient.addColorStop(middleRightStop, middleColorAtY);
                            lateralGradient.addColorStop(rightPeakStop, innerColorAtY);
                            lateralGradient.addColorStop(1.00, innerColorAtY);
                            ctx.fillStyle = lateralGradient;
                            ctx.fillRect(gradientLeftX, pixelY, gradientSpan, 1);
                        }
                        ctx.restore();

                        ctx.save();
                        ctx.strokeStyle = outlineColor;
                        ctx.lineWidth = Math.max(0.70, borderWidth * 0.72);
                        traceTreadZoneShape(geom.zx, geom.zw, geom.leftBottom, geom.centerBottom, geom.rightBottom, zone, geom.cornerRadius);
                        ctx.stroke();
                        ctx.restore();
                    }

                    for (var j = 0; j < 3; j++) {
                        var labelScale = (zoneEdgeScale[j] + zoneRemainingScaleBySection[j] + zoneEdgeScale[j + 1]) / 3;
                        var labelY = treadTopY + treadH * labelScale * (11.5 / 12);
                        var displayedSurfaceTemp = continuousFieldTemperature(j, 1.0);
                        ctx.save();
                        ctx.textAlign = "center";
                        ctx.textBaseline = "middle";
                        ctx.fillStyle = "rgba(255,255,255,0.94)";
                        ctx.font = 'bold ' + Math.max(4.0, Math.min(sectionW[j] * 0.19, tempTextH * 0.54)) + 'pt "Lucida Console", Monaco, monospace';
                        ctx.shadowColor = "rgba(0,0,0,0.92)";
                        ctx.shadowBlur = 2;
                        ctx.fillText(Math.round(finiteOr(displayedSurfaceTemp, temps[j])), sectionCenter[j], labelY);
                        ctx.restore();
                    }

                    var loadTriangleWidth = Math.max(7, tyreW * 0.11);
                    var loadTriangleHeight = Math.max(6, tyreH * 0.085);
                    var loadTriangleY = tyreY + tyreH + Math.max(3, tyreH * 0.03);
                    var loadBiasValue = Number(loadBias);
                    if (!isFinite(loadBiasValue)) loadBiasValue = 0;
                    loadBiasValue = Math.max(-1, Math.min(1, loadBiasValue));
                    var loadTriangleCenterX = cx + loadBiasValue * (tyreW * 0.4840);
                    ctx.save();
                    ctx.fillStyle = "rgba(255,60,60,0.90)";
                    ctx.strokeStyle = "rgba(255,255,255,0.92)";
                    ctx.lineWidth = Math.max(0.9, borderWidth * 0.9);
                    ctx.beginPath();
                    ctx.moveTo(loadTriangleCenterX, loadTriangleY);
                    ctx.lineTo(loadTriangleCenterX - loadTriangleWidth * 0.5, loadTriangleY + loadTriangleHeight);
                    ctx.lineTo(loadTriangleCenterX + loadTriangleWidth * 0.5, loadTriangleY + loadTriangleHeight);
                    ctx.closePath();
                    ctx.fill();
                    ctx.stroke();
                    ctx.restore();
                }

                function drawDebugOverlay(wheelData) {
                    if (!debugTempsEnabled || !wheelData || !wheelData.length) return;

                    var count = wheelData.length;
                    var cols = 2;
                    var rows = Math.max(1, Math.ceil(count / cols));
                    var scale = Math.max(0.70, Math.min(c.width / 100, c.height / 78));
                    var gap = Math.max(1, 1.4 * scale);
                    var cardW = (c.width - gap * (cols + 1)) / cols;
                    var cardH = (c.height - gap * (rows + 1)) / rows;
                    var radius = Math.max(2, 3.2 * scale);
                    var pad = Math.max(1.2, 2.0 * scale);

                    var targetPx = 9.0 * scale;
                    var lineHeight = Math.min(cardH * 0.235, targetPx * 1.12);
                    var fontPx = Math.max(6.5 * scale, Math.min(targetPx, lineHeight * 0.91));
                    var smallPx = Math.max(5.0 * scale, fontPx * 0.62);

                    function finiteNumber(value, fallback) {
                        value = Number(value);
                        return isFinite(value) ? value : fallback;
                    }
                    function pct01(value) {
                        value = finiteNumber(value, 0);
                        return Math.round(Math.max(0, Math.min(1, value)) * 100);
                    }
                    function fitFont(text, maxWidth, startPx) {
                        var px = startPx;
                        ctx.font = 'bold ' + px.toFixed(2) + 'px "Lucida Console", Monaco, monospace';
                        var measured = ctx.measureText(text).width;
                        if (measured > maxWidth && measured > 0) {
                            px *= maxWidth / measured;
                            ctx.font = 'bold ' + px.toFixed(2) + 'px "Lucida Console", Monaco, monospace';
                        }
                        return px;
                    }

                    for (var i = 0; i < count; i++) {
                        var wd = wheelData[i] || {};
                        var row = Math.floor(i / cols);
                        var col = i % cols;
                        var x = gap + col * (cardW + gap);
                        var y = gap + row * (cardH + gap);

                        var temps = wd.temp && wd.temp.length ? wd.temp : [0,0,0,0];
                        var slideLoad = pct01(wd.brush_sliding_load_fraction);
                        var uplift = finiteNumber(wd.baseline_grip_uplift, 1);
                        var mechanical = finiteNumber(wd.mechanical_grip_multiplier, 1);
                        var total = finiteNumber(wd.total_model_grip_multiplier, finiteNumber(wd.tyreGrip, 1));
                        var surfaceC = finiteNumber(wd.surface_avg_temp, finiteNumber(wd.surface_grip_temp_c, temps[1] || temps[0] || 0));
                        var treadC = finiteNumber(wd.bulk_tread_avg_temp, finiteNumber(wd.avg_temp, temps[1] || temps[0] || 0));
                        var coreC = finiteNumber(wd.core_temp, temps[3] || treadC);
                        var flashC = finiteNumber(wd.flash_temp, surfaceC);
                        var dirtActive = wd.rally_dirt_model_active === true;
                        var blockC = finiteNumber(wd.rally_dirt_block_temp_c, treadC);
                        var blockHeight = pct01(wd.rally_block_height_health);
                        var activeEdge = pct01(wd.rally_block_active_edge_health);
                        var dirtTempGrip = finiteNumber(wd.rally_dirt_temp_multiplier, 1);
                        var dirtWearGrip = finiteNumber(wd.rally_dirt_directional_wear_multiplier, 1);
                        var dirtCode = String(wd.rally_surface_class || "dirt").replace("loose_gravel", "LGR").replace("packed_gravel", "PGR").substring(0, 3).toUpperCase();

                        var lines = [
                            'S' + Math.round(surfaceC) + ' T' + Math.round(treadC),
                            'C' + Math.round(coreC) + ' F' + Math.round(flashC),
                            'U' + uplift.toFixed(2) + ' M' + mechanical.toFixed(2),
                            'X' + total.toFixed(2) + ' B' + slideLoad
                        ];
                        if (dirtActive) {
                            lines = [
                                dirtCode + ' T' + Math.round(blockC),
                                'H' + blockHeight + ' E' + activeEdge,
                                'T' + dirtTempGrip.toFixed(2) + ' W' + dirtWearGrip.toFixed(2),
                                'X' + total.toFixed(2) + ' B' + slideLoad
                            ];
                        }

                        ctx.save();
                        ctx.fillStyle = 'rgba(3,7,10,0.82)';
                        ctx.strokeStyle = 'rgba(150,225,255,0.78)';
                        ctx.lineWidth = Math.max(0.8, 1.0 * scale);
                        roundRect(ctx, x, y, cardW, cardH, radius, true, true);

                        ctx.textAlign = 'left';
                        ctx.textBaseline = 'top';
                        ctx.fillStyle = 'rgba(120,220,255,0.82)';
                        ctx.font = 'bold ' + smallPx.toFixed(2) + 'px Arial, sans-serif';
                        ctx.fillText(String(wd.name || (i + 1)), x + pad, y + Math.max(0.5, 0.6 * scale));

                        ctx.textAlign = 'center';
                        ctx.textBaseline = 'middle';
                        ctx.fillStyle = 'rgba(255,255,255,1)';
                        ctx.shadowColor = 'rgba(0,0,0,0.95)';
                        ctx.shadowBlur = Math.max(1.5, 2.0 * scale);
                        ctx.shadowOffsetX = 0;
                        ctx.shadowOffsetY = Math.max(0.5, 0.7 * scale);

                        var usableW = Math.max(8, cardW - pad * 2);
                        var firstY = y + cardH * 0.18;
                        var stepY = cardH * 0.225;
                        for (var li = 0; li < lines.length; li++) {
                            fitFont(lines[li], usableW, fontPx);
                            ctx.fillText(lines[li], x + cardW * 0.5, firstY + li * stepY);
                        }
                        ctx.restore();
                    }
                }

                function updateTyreProfileSummary(wheelData) {
                    if (!tyreProfileCard || !tyreProfileLines) return;
                    wheelData = wheelData || [];
                    var heading = tyreProfileCard.querySelector(".tyre-profile-heading");
                    if (!wheelData.length) {
                        if (heading.textContent !== "Auto tyre profile — waiting") heading.textContent = "Auto tyre profile — waiting";
                        if (tyreProfileStructureSignature !== "waiting") {
                            tyreProfileLines.textContent = "No wheel data";
                            tyreProfileEntryElements = {};
                            tyreProfileStructureSignature = "waiting";
                        }
                        return;
                    }

                    var wheelOrder = { FL: 0, FR: 1, RL: 2, RR: 3 };
                    function wheelSortValue(name) {
                        name = String(name || "").toUpperCase();
                        if (wheelOrder[name] !== undefined) return wheelOrder[name];
                        if (name.indexOf("FL") >= 0) return 0;
                        if (name.indexOf("FR") >= 0) return 1;
                        if (name.indexOf("RL") >= 0) return 2;
                        if (name.indexOf("RR") >= 0) return 3;
                        return 100;
                    }
                    function safeNumber(value, fallback) {
                        value = Number(value);
                        return isFinite(value) ? value : fallback;
                    }
                    function average(values, fallback) {
                        if (!values.length) return fallback;
                        var total = 0;
                        values.forEach(function (value) { total += value; });
                        return total / values.length;
                    }
                    function makeStat(label) {
                        var cell = document.createElement("div");
                        cell.className = "tyre-profile-stat";
                        var labelElement = document.createElement("span");
                        labelElement.className = "tyre-profile-stat-label";
                        labelElement.textContent = label;
                        var valueElement = document.createElement("span");
                        valueElement.className = "tyre-profile-stat-value";
                        valueElement.textContent = "—";
                        cell.appendChild(labelElement);
                        cell.appendChild(valueElement);
                        return { cell: cell, value: valueElement };
                    }
                    function makeStructuralPsiStat(entry) {
                        var cell = document.createElement("div");
                        cell.className = "tyre-profile-stat";
                        var labelElement = document.createElement("span");
                        labelElement.className = "tyre-profile-stat-label";
                        labelElement.textContent = "STRUCT PSI";
                        var input = document.createElement("input");
                        input.className = "tyre-profile-struct-input";
                        input.type = "text";
                        input.inputMode = "decimal";
                        input.autocomplete = "off";
                        input.spellcheck = false;
                        input.title = "Neutral/reference PSI for this tyre's structural load distribution. Type a PSI value and press Enter. Type AUTO to return to the detected profile default. This does not alter BeamNG's actual tyre pressure.";
                        input.addEventListener("mousedown", stopUiPropagation);
                        input.addEventListener("click", stopUiPropagation);
                        input.addEventListener("focus", function () {
                            activeTuningInput = input;
                            activeTuningDefinition = null;
                            setKeyboardCapture(true, input);
                            try { input.select(); } catch (e) {}
                        });
                        function commitStructuralPsi() {
                            var raw = String(input.value || "").trim();
                            var key = String(entry.internalName || "").toLowerCase();
                            if (raw.toUpperCase() === "AUTO" || raw === "") {
                                delete structuralPsiOverrides[key];
                                delete structuralPsiApplied[key];
                                saveStructuralPsiOverrides();
                                clearTyreStructuralPsi(entry.internalName);
                                input.classList.remove("manual");
                                setStatus(entry.name + " structural PSI = AUTO");
                                return;
                            }
                            var value = Number(raw);
                            if (!isFinite(value)) { input.value = "AUTO"; return; }
                            value = Math.max(3, value);
                            structuralPsiOverrides[key] = value;
                            structuralPsiApplied[key] = value;
                            saveStructuralPsiOverrides();
                            sendTyreStructuralPsi(entry.internalName, value);
                            input.value = value.toFixed(1);
                            input.classList.add("manual");
                            setStatus(entry.name + " structural target = " + value.toFixed(1) + " psi");
                        }
                        input.addEventListener("keydown", function (event) {
                            if (event.key === "Enter") { commitStructuralPsi(); input.blur(); event.preventDefault(); }
                            else if (event.key === "Escape") { input.blur(); }
                            event.stopPropagation();
                        });
                        input._commitStructuralPsi = commitStructuralPsi;
                        input.addEventListener("blur", commitStructuralPsi);
                        cell.appendChild(labelElement);
                        cell.appendChild(input);
                        return { cell: cell, input: input };
                    }

                    var groups = {};
                    wheelData.forEach(function (wheel) {
                        var profile = wheel.tyre_profile_label || "Standard / road";
                        var name = wheel.tyre_name || "Unknown tyre";
                        var temp = safeNumber(wheel.working_temp, 0);
                        var overheat = safeNumber(wheel.effective_overheat_start || wheel.profile_overheat_start, 0);
                        var source = wheel.tyre_profile_source || "fallback";
                        var internalName = wheel.tyre_internal_name || "unknown_tyre";
                        var reference = safeNumber(wheel.tyre_pressure_reference_psi, 30);
                        var structuralReference = safeNumber(wheel.cross_tread_reference_pressure_psi, 30);
                        var structuralReferenceSource = wheel.cross_tread_reference_pressure_source || "profile-fallback";
                        var key = [profile, name, temp.toFixed(1), overheat.toFixed(1), source, internalName].join("|");
                        if (!groups[key]) {
                            groups[key] = {
                                key: key, profile: profile, name: name, temp: temp,
                                overheat: overheat, source: source, internalName: internalName,
                                reference: reference, structuralReference: structuralReference, structuralReferenceSources: [],
                                wheels: [], pressures: [], airTemps: [], pressureStates: [], uplifts: [], upliftSources: []
                            };
                        }
                        groups[key].wheels.push(wheel.name || "wheel");
                        groups[key].pressures.push(safeNumber(wheel.tyre_pressure_psi, reference));
                        groups[key].airTemps.push(safeNumber(wheel.tyre_air_temp, temp));
                        groups[key].pressureStates.push(wheel.pressure_control_state || "initialising");
                        groups[key].structuralReference = structuralReference;
                        groups[key].structuralReferenceSources.push(structuralReferenceSource);
                        groups[key].uplifts.push(safeNumber(wheel.baseline_grip_uplift, 1));
                        groups[key].upliftSources.push(wheel.baseline_grip_uplift_source || "unknown");
                    });

                    var entries = Object.keys(groups).map(function (key) {
                        var entry = groups[key];
                        entry.wheels.sort(function (a, b) {
                            var orderDifference = wheelSortValue(a) - wheelSortValue(b);
                            return orderDifference || String(a).localeCompare(String(b));
                        });
                        entry.pressure = average(entry.pressures, entry.reference);
                        entry.airTemp = average(entry.airTemps, entry.temp);
                        entry.uplift = average(entry.uplifts, 1);
                        entry.sortValue = wheelSortValue(entry.wheels[0]);
                        return entry;
                    });
                    entries.sort(function (a, b) {
                        return a.sortValue - b.sortValue || a.profile.localeCompare(b.profile) || a.name.localeCompare(b.name);
                    });

                    var uniqueProfiles = {};
                    entries.forEach(function (entry) { uniqueProfiles[entry.profile] = true; });
                    var profileNames = Object.keys(uniqueProfiles).sort();
                    var headingPrefix = currentTyreProfilePreset === "auto" ? "Auto tyre profile — " : "Manual tyre profile — ";
                    var headingText = headingPrefix + (profileNames.length === 1 ? profileNames[0] : "Mixed");
                    if (heading.textContent !== headingText) heading.textContent = headingText;

                    var structureSignature = entries.map(function (entry) {
                        return entry.key + "|" + entry.wheels.join("/");
                    }).join("||");

                    if (structureSignature !== tyreProfileStructureSignature) {
                        tyreProfileLines.textContent = "";
                        tyreProfileEntryElements = {};
                        entries.forEach(function (entry) {
                            var row = document.createElement("div");
                            row.className = "tyre-profile-entry";

                            var top = document.createElement("div");
                            top.className = "tyre-profile-entry-top";
                            var wheelsElement = document.createElement("span");
                            wheelsElement.className = "tyre-profile-wheels";
                            wheelsElement.textContent = entry.wheels.join("/");
                            var kindElement = document.createElement("span");
                            kindElement.className = "tyre-profile-kind";
                            kindElement.textContent = entry.profile;
                            var sourceElement = document.createElement("span");
                            sourceElement.className = "tyre-profile-source";
                            sourceElement.textContent = entry.source === "fallback" ? "FALLBACK" : entry.source;
                            top.appendChild(wheelsElement);
                            top.appendChild(kindElement);
                            top.appendChild(sourceElement);

                            var part = document.createElement("div");
                            part.className = "tyre-profile-part";
                            part.textContent = entry.name + "  [" + entry.internalName + "]";
                            part.title = "Part: " + entry.name + " | Internal: " + entry.internalName;

                            var stats = document.createElement("div");
                            stats.className = "tyre-profile-stats";
                            var work = makeStat("WORK °C");
                            var air = makeStat("AIR °C");
                            var psi = makeStat("LIVE PSI");
                            var reference = makeStat("TUNE PSI");
                            var structural = makeStructuralPsiStat(entry);
                            var fade = makeStat("FADE °C");
                            var uplift = makeStat("UPLIFT ×");
                            [work, air, psi, reference, structural, fade, uplift].forEach(function (stat) { stats.appendChild(stat.cell); });

                            row.appendChild(top);
                            row.appendChild(part);
                            row.appendChild(stats);
                            tyreProfileLines.appendChild(row);
                            tyreProfileEntryElements[entry.key] = {
                                row: row, work: work.value, air: air.value, psi: psi.value,
                                reference: reference.value, structural: structural.input, fade: fade.value, uplift: uplift.value
                            };
                        });
                        tyreProfileStructureSignature = structureSignature;
                    }

                    entries.forEach(function (entry) {
                        var elements = tyreProfileEntryElements[entry.key];
                        if (!elements) return;
                        elements.work.textContent = formatNumber(entry.temp);
                        elements.air.textContent = formatNumber(entry.airTemp);
                        elements.psi.textContent = formatNumber(entry.pressure);
                        elements.reference.textContent = formatNumber(entry.reference);
                        var overrideKey = String(entry.internalName || "").toLowerCase();
                        var storedStruct = Number(structuralPsiOverrides[overrideKey]);
                        var hasStoredStruct = isFinite(storedStruct) && storedStruct >= 3;
                        var runtimeHasManualStruct = entry.structuralReferenceSources.indexOf("manual-tyre") >= 0;
                        var runtimeStructMatches = Math.abs(entry.structuralReference - storedStruct) < 0.02;
                        if (hasStoredStruct && runtimeHasManualStruct && runtimeStructMatches) {
                            structuralPsiApplied[overrideKey] = storedStruct;
                        } else if (hasStoredStruct && structuralPsiApplied[overrideKey] !== ("pending:" + storedStruct)) {
                            sendTyreStructuralPsi(entry.internalName, storedStruct);
                            structuralPsiApplied[overrideKey] = "pending:" + storedStruct;
                        }
                        if (document.activeElement !== elements.structural) {
                            elements.structural.value = formatNumber(hasStoredStruct ? storedStruct : entry.structuralReference);
                        }
                        elements.structural.classList.toggle("manual", hasStoredStruct || entry.structuralReferenceSources.indexOf("manual-tyre") >= 0);
                        elements.fade.textContent = formatNumber(entry.overheat);
                        elements.uplift.textContent = formatNumber(entry.uplift);
                        elements.row.title = "Pressure control: " + entry.pressureStates.join(", ") +
                            " | Tuned hot reference: " + formatNumber(entry.reference) + " psi" +
                            " | Structural neutral target: " + formatNumber(entry.structuralReference) + " psi (" + entry.structuralReferenceSources.join(", ") + ")" +
                            " | Grip uplift: " + formatNumber(entry.uplift) + "x (" + entry.upliftSources.join(", ") + ")";
                    });
                }

                function updateTuningInputs(values) {
                    if (!values) return;
                    Object.keys(values).forEach(function (key) {
                        var value = Number(values[key]);
                        if (!isFinite(value)) return;
                        currentTuningValues[key] = value;
                        if (key === "arcade_handling_mode_enabled") {
                            updateArcadeHandlingButton(value >= 0.5);
                        }
                        var input = tuningInputs[key];
                        if (input && document.activeElement !== input && !input.classList.contains("invalid")) {
                            var matchingDefinition = null;
                            tuningGroups.some(function (group) {
                                return group.settings.some(function (definition) {
                                    if (definition.key === key) { matchingDefinition = definition; return true; }
                                    return false;
                                });
                            });
                            if (matchingDefinition && matchingDefinition.type === "checkbox") {
                                input.checked = value >= 0.5;
                            } else {
                                input.value = formatTuningValue(matchingDefinition, value);
                                if (matchingDefinition && matchingDefinition.type === "range" && input._valueLabel) input._valueLabel.textContent = input.value + "%";
                                input.classList.remove("invalid");
                            }
                        }
                    });
                }

                buildSettingsPanel();
                drawWaitingState();
                StreamsManager.add(streamsList);
                syncVehicleDebugTelemetry(false);

                scope.$on("$destroy", function () {
                    clearArcadeHandlingAckTimer();
                    if (wearClickTimer !== null) { clearTimeout(wearClickTimer); wearClickTimer = null; }
                    clearDebugCanvasGesture();
                    setKeyboardCapture(false);
                    syncVehicleDebugTelemetry(false);
                    StreamsManager.remove(streamsList);
                    if (settingsPanel.parentNode) settingsPanel.parentNode.removeChild(settingsPanel);
                    if (fullscreenDebugOverlay.parentNode) fullscreenDebugOverlay.parentNode.removeChild(fullscreenDebugOverlay);
                });

                scope.$on("app:resized", function (event, data) {
                    c.width = Math.max(1, data.width);
                    c.height = Math.max(1, data.height);
                    drawWaitingState();
                });

                scope.$on("streamsUpdate", function (event, streams) {
                    var dataStream = streams.TyreWearThermals;
                    if (!dataStream) return;

                    wearEnabled = dataStream.wear_enabled !== false;
                    thermalsPaused = dataStream.thermals_paused === true;
                    if (typeof dataStream.arcade_handling_mode_enabled !== "undefined") {
                        updateArcadeHandlingButton(dataStream.arcade_handling_mode_enabled === true);
                    }
                    if (typeof dataStream.arcade_handling_mode_revision !== "undefined") {
                        var streamedModeRevision = Number(dataStream.arcade_handling_mode_revision);
                        if (isFinite(streamedModeRevision)) {
                            arcadeHandlingRevision = streamedModeRevision;
                            if (arcadeHandlingPendingState !== null
                                && arcadeHandlingRevision > arcadeHandlingPendingRevision
                                && arcadeHandlingEnabled === arcadeHandlingPendingState) {
                                clearArcadeHandlingAckTimer();
                                arcadeHandlingPendingState = null;
                                arcadeHandlingPendingRevision = -1;
                                if (arcadeHandlingButton) arcadeHandlingButton.classList.remove("mode-error");
                                setStatus(arcadeHandlingEnabled
                                    ? "Arcade tyre mode ON — vehicle ACK"
                                    : "Realistic tyre mode ON — vehicle ACK");
                            }
                        }
                    }
                    appliedTyreProfilePreset = String(dataStream.tyre_profile_preset || "auto").toLowerCase();
                    appliedSlickCompoundPreset = String(dataStream.slick_compound_preset || "medium").toLowerCase();
                    appliedRallySurfacePreset = String(dataStream.rally_surface_preset || "asphalt").toLowerCase();
                    appliedRallyCompoundPreset = String(dataStream.rally_compound_preset || "medium").toLowerCase();

                    var streamedRacingMode = dataStream.pit_racing_mode_enabled === true;
                    updateRacingModeButton(streamedRacingMode);
                    updatePitPressureInputs(dataStream);
                    var streamedPreheatDefault = Number(dataStream.preheat_default_target_c);
                    if (preheatTempInput && !preheatTempInitialised && isFinite(streamedPreheatDefault)) {
                        preheatTempInput.value = streamedPreheatDefault.toFixed(1);
                        preheatTempInput.dataset.lastValidTemp = streamedPreheatDefault.toFixed(1);
                        preheatTempInitialised = true;
                        preheatTempUserEdited = false;
                        if (!advancedPreheatState.custom) syncAdvancedPreheatToGlobal(false);
                    }

                    var appliedPreheatPresetSignature = [
                        appliedTyreProfilePreset, appliedSlickCompoundPreset,
                        appliedRallySurfacePreset, appliedRallyCompoundPreset
                    ].join("|");
                    if (!streamedRacingMode && lastAppliedPreheatPresetSignature !== null
                        && appliedPreheatPresetSignature !== lastAppliedPreheatPresetSignature
                        && preheatTempInput && isFinite(streamedPreheatDefault)
                        && document.activeElement !== preheatTempInput) {
                        preheatTempInput.value = streamedPreheatDefault.toFixed(1);
                        preheatTempInput.dataset.lastValidTemp = streamedPreheatDefault.toFixed(1);
                        preheatTempInput.classList.remove("invalid");
                        preheatTempUserEdited = false;
                        if (!advancedPreheatState.custom) syncAdvancedPreheatToGlobal(false);
                    }
                    lastAppliedPreheatPresetSignature = appliedPreheatPresetSignature;

                    if (streamedRacingMode) {
                        updatePreheatButtonMode(dataStream.pit_stop_staged_preheat_mode || "quick");
                        var stagedPreheatTarget = Number(dataStream.pit_stop_staged_preheat_target_c);
                        if (preheatTempInput && isFinite(stagedPreheatTarget) && document.activeElement !== preheatTempInput) {
                            preheatTempInput.value = stagedPreheatTarget.toFixed(1);
                            preheatTempInput.dataset.lastValidTemp = stagedPreheatTarget.toFixed(1);
                        }
                        if (dataStream.pit_stop_staged_preheat_advanced === true) {
                            var af = Number(dataStream.pit_stop_staged_preheat_fl_c), ar = Number(dataStream.pit_stop_staged_preheat_fr_c);
                            var al = Number(dataStream.pit_stop_staged_preheat_rl_c), arr = Number(dataStream.pit_stop_staged_preheat_rr_c);
                            if (isFinite(af) && isFinite(ar) && isFinite(al) && isFinite(arr)) {
                                advancedPreheatState.custom = true;
                                advancedPreheatState.temps.FL = af; advancedPreheatState.temps.FR = ar;
                                advancedPreheatState.temps.RL = al; advancedPreheatState.temps.RR = arr;
                                saveAdvancedPreheatState();
                                renderAdvancedPreheatPanel();
                            }
                        }
                    }
                    if (streamedRacingMode) {
                        updateTyreProfilePresetButtons(dataStream.pit_stop_staged_profile || appliedTyreProfilePreset);
                        updateSlickCompoundPresetButtons(dataStream.pit_stop_staged_slick_compound || appliedSlickCompoundPreset);
                        updateRallySurfacePresetButtons(dataStream.pit_stop_staged_rally_surface || appliedRallySurfacePreset);
                        updateRallyCompoundPresetButtons(dataStream.pit_stop_staged_rally_compound || appliedRallyCompoundPreset);
                        setPitProgressState(
                            dataStream.pit_stop_state || "waiting",
                            dataStream.pit_stop_message || "WAITING PIT STOP",
                            dataStream.pit_stop_progress,
                            dataStream.pit_stop_remaining_s
                        );
                    } else {
                        updateTyreProfilePresetButtons(appliedTyreProfilePreset);
                        updateSlickCompoundPresetButtons(appliedSlickCompoundPreset);
                        updateRallySurfacePresetButtons(appliedRallySurfacePreset);
                        updateRallyCompoundPresetButtons(appliedRallyCompoundPreset);
                        setPitProgressState("off", "PIT MANAGER", 0, 0);
                    }
                    updateProfilePresetReadOnly(dataStream.advanced_profile_read_only === true);
                    if (tyreProfileNote) {
                        var isAutoProfile = dataStream.advanced_profile_read_only === true;
                        var advKey = String(dataStream.advanced_profile_key || "standard").replace(/_/g, " ");
                        var mixedSuffix = dataStream.advanced_profile_mixed === true ? " · mixed wheels / representative" : "";
                        var noteText = isAutoProfile
                            ? "EXP values: " + advKey + " detected (read-only actual values" + mixedSuffix + ") · PSI LIVE = BeamNG + axle override · cavity " + formatNumber(dataStream.pressure_update_hz || 5) + " Hz"
                            : "EXP values: " + advKey + " (manual editable) · PSI LIVE = BeamNG + axle override · cavity " + formatNumber(dataStream.pressure_update_hz || 5) + " Hz";
                        if (tyreProfileNote.textContent !== noteText) tyreProfileNote.textContent = noteText;
                        tyreProfileNote.title = "Thermal preset: " + (dataStream.thermal_preset_label || "General / drift-focused") + ". During normal driving BeamNG owns instantaneous physical pressure/deformation and KTS adds only the cavity-temperature delta. FRONT/REAR PSI above is an explicit service override: it writes the requested live gauge pressure once and rebases the thermal anchor so later heating/cooling continues from that value. STRUCT PSI remains a separate neutral/reference value used only by the structural/cross-tread model.";
                    }
                    updateTuningNativeValues(dataStream.tuning_native_values);
                    updateTuningInputs(dataStream.tuning_values);
                    var liveTreadEnabled = !!(dataStream.tuning_values
                        && Number(dataStream.tuning_values.sport_physical_stiffness_enabled) >= 0.5);
                    updateLiveTreadPhysicalReadOnly(liveTreadEnabled, dataStream);
                    if (sportStiffnessStatus && dataStream.sport_physical_stiffness) {
                        var ps = dataStream.sport_physical_stiffness;
                        var modeLabel = ps.active_wheels > 0 ? "LIVE" :
                            (dataStream.thermals_paused === true ? "THERMAL OFF / NATIVE" : "WAITING");
                        var caPct = Number(ps.ca_factor || 1) * 100;
                        var realCaPct = Number(ps.realistic_ca_factor || ps.ca_factor || 1) * 100;
                        var treadPct = Number(ps.applied_tread_scale || 1) * 100;
                        var targetTreadPct = Number(ps.target_tread_scale || ps.applied_tread_scale || 1) * 100;
                        var safeTreadPct = Number(ps.stability_safe_spring_limit || 1.84) * 100;
                        var dampPct = Number(ps.applied_tread_damp_scale || 1) * 100;
                        var targetDampPct = Number(ps.target_tread_damp_scale || ps.applied_tread_damp_scale || 1) * 100;
                        var stabilityModelId = String(ps.stability_model_id || "legacy-last-fallback");
                        var frontSafePct = Number(ps.stability_front_safe_spring_limit || 0) * 100;
                        var rearSafePct = Number(ps.stability_rear_safe_spring_limit || 0) * 100;
                        var frontDampPct = Number(ps.stability_front_applied_damp_scale || 0) * 100;
                        var rearDampPct = Number(ps.stability_rear_applied_damp_scale || 0) * 100;
                        var familySafetyText = (frontSafePct > 0 || rearSafePct > 0)
                            ? "  |  FAMILY F " + frontSafePct.toFixed(1) + "%/" + frontDampPct.toFixed(1) + "%D" +
                              " R " + rearSafePct.toFixed(1) + "%/" + rearDampPct.toFixed(1) + "%D"
                            : "";
                        sportStiffnessStatus.textContent =
                            modeLabel + "  |  T " + Number(ps.structural_temp_c || 0).toFixed(1) + "°C" +
                            "  |  Cα " + caPct.toFixed(1) + "% (REAL " + realCaPct.toFixed(1) + "%)" +
                            "  |  SPRING " + treadPct.toFixed(1) + "% (REQ " + targetTreadPct.toFixed(1) + "% / SAFE " + safeTreadPct.toFixed(1) + "%)" +
                            "  |  DAMP " + dampPct.toFixed(1) + "% (REQ " + targetDampPct.toFixed(1) + "%)" +
                            familySafetyText +
                            "  |  " + Number(ps.width_mm || 0).toFixed(0) + "mm / AR " + Number(ps.aspect_ratio || 0).toFixed(2);
                        sportStiffnessStatus.title = "Stability model: " + stabilityModelId +
                            " · native tread spring " + Number(ps.native_tread_spring || 0).toFixed(0) +
                            " · native tread damping " + Number(ps.native_tread_damp || 0).toFixed(1) +
                            " · support K/tread " + Number(ps.structural_support_spring_eq_npm || 0).toFixed(0) +
                            " · fixed C/tread " + Number(ps.structural_fixed_damping_eq || 0).toFixed(1) +
                            " · budget " + (Number(ps.structural_budget_npm || 0) / 1000).toFixed(1) + " kN/m" +
                            " · zero-D tread capacity " + (Number(ps.structural_zero_damping_capacity_npm || 0) / 1000).toFixed(1) + " kN/m" +
                            " · native budget use " + (Number(ps.structural_native_budget_utilization || 0) * 100).toFixed(1) + "%" +
                            ". SAFE and damping correction are calculated per detected front/rear construction family; REQ is the temperature/wear target before smoothing.";
                    }
                    if (structureTunerStatus && dataStream.structure_tuner_stats) {
                        var st = dataStream.structure_tuner_stats;
                        var geo = st.geometry || {};
                        var geoAll = geo.all || geo;
                        var geoFront = geo.front || {};
                        var geoRear = geo.rear || {};
                        var geoText = geo.baselineCaptured === true
                            ? "  |  WΔ A/F/R " + Number(geoAll.treadDeltaPct || 0).toFixed(2) + "% / " +
                              Number(geoFront.treadDeltaPct || 0).toFixed(2) + "% / " +
                              Number(geoRear.treadDeltaPct || 0).toFixed(2) + "%" +
                              "  |  SΔ F/R " + Number(geoFront.sideDeltaPct || 0).toFixed(2) + "% / " +
                              Number(geoRear.sideDeltaPct || 0).toFixed(2) + "%"
                            : "  |  GEOMETRY BASELINE NOT CAPTURED";
                        structureTunerStatus.textContent =
                            "BEAMS " + Number(st.cached || 0) +
                            "  |  APPLIED " + Number(st.applied || 0) +
                            "  |  REF " + Number(st.ref_applied || 0) + "/" + Number(st.ref_failed || 0) +
                            "  |  S/T/R " + Number(st.side || 0) + "/" + Number(st.tread || 0) + "/" + Number(st.reinf || 0) +
                            "  |  ENDPOINTS " + Number(st.endpoint_resolved || 0) + "/" + Number(st.cached || 0) +
                            "  |  SKIP " + Number(st.skipped || 0) +
                            geoText +
                            "  |  PRE T " + (Number(st.tread_precompression_scale || 1) * 100).toFixed(1) + "%" +
                            "  |  WRITE REV " + Number(st.revision || 0) +
                            "  |  " + String(st.status || "unknown").toUpperCase();
                    }
                    ctx.setTransform(1, 0, 0, 1, 0, 0);
                    ctx.clearRect(0, 0, c.width, c.height);
                    wheelClickBounds = [];
                    ctx.textAlign = "center";

                    var wheelData = dataStream.data || [];
                    var visualWheelData = orderWheelDataForVehicleView(wheelData);
                    if (debugTempsEnabled) updateFullscreenDebug(visualWheelData);
                    else fullscreenDebugLatestWheelData = [];
                    updateTyreProfileSummary(visualWheelData);
                    for (var i = 0; i < visualWheelData.length; i++) {
                        drawWheelData(
                            visualWheelData[i].name,
                            (visualWheelData[i].surface_temp && visualWheelData[i].surface_temp.length >= 3) ? visualWheelData[i].surface_temp : visualWheelData[i].temp,
                            visualWheelData[i].working_temp,
                            visualWheelData[i].condition,
                            visualWheelData[i].camber,
                            i,
                            visualWheelData.length,
                            visualWheelData[i].tyre_pressure_psi,
                            visualWheelData[i].tyre_pressure_reference_psi,
                            visualWheelData[i].preheat_hot_pressure_target_psi,
                            visualWheelData[i].tyre_air_temp,
                            visualWheelData[i].load_bias,
                            visualWheelData[i].avg_temp,
                            visualWheelData[i].flash_temp,
                            visualWheelData[i].temp && visualWheelData[i].temp.length > 3 ? visualWheelData[i].temp[3] : visualWheelData[i].tyre_air_temp,
                            visualWheelData[i].patch_hot_fraction,
                            visualWheelData[i].patch_effective_temp,
                            visualWheelData[i].surface_hotspot_contact,
                            visualWheelData[i].patch_grip_multiplier,
                            visualWheelData[i].brush_sliding_length_fraction,
                            visualWheelData[i].native_dry_patch_ratio,
                            visualWheelData[i].flash_thermal_modifier,
                            visualWheelData[i].kinematic_slip_angle_deg,
                            visualWheelData[i].brush_critical_angle_deg,
                            visualWheelData[i].tread_nominal_depth_mm,
                            visualWheelData[i].tread_remaining_depth_mm,
                            visualWheelData[i].tread_nonwearable_reserve_mm,
                            visualWheelData[i].tread_wearable_remaining_mm,
                            visualWheelData[i].tread_remaining_outer_mm,
                            visualWheelData[i].tread_remaining_middle_mm,
                            visualWheelData[i].tread_remaining_inner_mm,
                            visualWheelData[i].tread_field_outer,
                            visualWheelData[i].tread_field_middle,
                            visualWheelData[i].tread_field_inner,
                            visualWheelData[i].tyre_sidewall_outer_temp,
                            visualWheelData[i].tyre_sidewall_inner_temp,
                            visualWheelData[i].tyre_rim_temp,
                            visualWheelData[i].circumferential_local_l1_delta_c,
                            visualWheelData[i].circumferential_local_l2_delta_c,
                            visualWheelData[i].circumferential_local_l3_delta_c,
                            visualWheelData[i].circumferential_local_l4_delta_c
                        );
                    }
                    if (debugTempsEnabled) drawDebugOverlay(visualWheelData);
                    drawWearToggle(wearEnabled, thermalsPaused);
                });
            }
        };
    }]);

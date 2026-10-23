-- Kagoni Tyre Simulation (KTS) v1.5.0 PUBLIC
-- Vehicle-side universal tyre simulation extension.
--
-- WORDS FOR CODE DIVERS :D
-- This project is heavily experiment-driven / vibe-coded, so some old naming survives, but the physics
-- has been researched, tested and repeatedly recalibrated over hundreds of development versions.
-- Research-backed blocks carry provenance tags and, for newer work, direct source URLs beside the
-- constants they constrain. Sources support the PHYSICAL RELATIONSHIP / trend unless a comment says a
-- value was measured directly; KTS's exact reduced-order coefficients remain engineering calibration.
-- Please preserve these comments/links during cleanup so solved decisions do not get "rediscovered" later.
--
-- QUICK RESEARCH MAP
-- [R1] Fiala brush model + Pacejka tyre-load/cornering-stiffness relationships.
-- [R2] Pegram et al. passenger-tyre combined-slip / critical-slip measurements.
-- [R3] Kobayashi, Weber & Gerdes (Stanford, 2024) tyre thermodynamics / drifting data.
-- [R4] Persson rubber-friction / flash-temperature and finite-slip-distance framework.
-- [R5] High-performance / motorsport Flat-Trac data (temperature-dependent grip/C_alpha and tread-depth stiffness).
-- [R6] Hewson (2005), "Method for estimating tyre cornering stiffness from basic tyre information".
-- [R7] Polley & Alleyne, dimensionless tyre-characteristic / aspect-ratio analysis.
-- [R8] Yap, SAE 881846 — load/inflation effects on transverse contact pressure.
-- [R9] Marshek et al., UT Austin/FHWA Report 386-1 (1985) — measured footprint pressure.
-- [R10] Suo et al. (2024) — carcass deformation / camber-related transverse load motion.
-- [R11] Liu & Cebon (Cambridge, 2025) — tread-rubber abrasion vs pressure/sliding speed.
-- [R12] Clark, "Mechanics of Pneumatic Tires" — radial-tyre hysteresis / rolling-loss distribution.
-- [R13] Fourier transient conduction + ideal-gas thermodynamics (basic physical laws).
-- [R14] Schuring, Skinner & Rae, SAE 810165 (1981) — loaded-tyre cavity airflow / peristaltic pumping.
-- [R15] Farroni et al., Meccanica (2021) — 3-D inner-chamber CFD / rotation-driven forced convection.
-- [R16] Rubber abrasion friction-work / directional-shear literature; longitudinal + lateral work are additive.
-- https://www.repository.cam.ac.uk/bitstreams/6829c4ac-3491-45e3-9e39-df5746406623/download
-- https://www.sciencedirect.com/science/article/pii/S0043164826002607
--
-- NEWER INLINE PROVENANCE CATALOGS (search these tags in this file)
-- [TEMP-R1..R3] Road/Sport/Sport-Plus-2R temperature-grip shape / product-class anchors.
-- TEMP-R1: https://pmc.ncbi.nlm.nih.gov/articles/PMC10934219/
-- TEMP-R2: https://www.tirerack.com/tires/tires.jsp?tireMake=Michelin&tireModel=Pilot+Sport+4s
-- TEMP-R3: https://marketing.michelin.co.uk/p/PDF/Technical%20Bulletin_PSC2R.pdf
-- [FLASH] Micro-flash localization, skid-burn/degradation bounds and compound destructive-skin ordering.
-- [TG-R1..R14] Tread depth, groove/void geometry, rubber k/rho/cp, FIA rally geometry and wear-class anchors.
-- [ASYM-R1..R2] Cup-2-R asymmetric shoulder/groove cooling evidence.
-- [GC-R1] Tyre-road thermal contact conductance anchor.
-- [GRIP-R1..R3] Physical tread-depth authority / frictional penetration scale.
-- [DE-R1..R3] Destructive sliding / pyrolysis-energy sink and decomposition-temperature evidence.
-- [CP-R1..R3] Contact-patch area, carcass-support pressure and low-pressure saturation model.
-- [RC-R1] Local road-contact heat exchange / signed circumferential boundary ownership.
-- [WS-R1..R3] Wear/tread-height -> cornering-stiffness evidence.
-- [WG-R1..R2] Wear-depth -> dry-grip ownership (road shaving evidence vs race performance-life cliff).
-- [BEAM] BeamNG-native slipEnergy / wheel integration provenance for the production friction-work heat path.
-- Detailed URLs for sourced entries are kept immediately above the blocks that use them below.

groundModels = {}
groundModelsLut = {}
beamstate = require("beamstate")

local tyre_utils = require("tyre_utils")
local tyre_init_data = {}

local lerp = tyre_utils.lerp
local sigmoid = tyre_utils.sigmoid

local M = {}

-- Traffic/AI performance gate. Default OFF means continuous KTS runs only
-- on the currently seated player vehicle; enabling the option restores
-- continuous KTS simulation on every spawned vehicle.
M._trafficSimulation = M._trafficSimulation or {
    enableAllSpawnedCars = false,
}

M.setEnableAllSpawnedCarsLocal = function(enabled)
    M._trafficSimulation.enableAllSpawnedCars = enabled == true
    return M._trafficSimulation.enableAllSpawnedCars
end

M._trafficSimulation.syncFromMailbox = function()
    if not obj or not obj.getLastMailbox then return M._trafficSimulation.enableAllSpawnedCars end
    local mailboxValue = tonumber(obj:getLastMailbox("ktsEnableAllSpawnedCars"))
    if mailboxValue ~= nil then
        M._trafficSimulation.enableAllSpawnedCars = mailboxValue >= 0.5
    end
    return M._trafficSimulation.enableAllSpawnedCars
end

M._trafficSimulation.shouldRun = function()
    if M._trafficSimulation.enableAllSpawnedCars == true then return true end
    return (playerInfo and playerInfo.firstPlayerSeated) and true or false
end

local OPTIMAL_PRESSURE = 206842
local PSI_TO_PA = 6894.757293168
local STANDARD_ATMOSPHERIC_PRESSURE_PA = 101325
local MIN_DYNAMIC_PRESSURE_PSI = 0
local MIN_NUMERIC_PRESSURE_PSI = 0.05
local WORKING_TEMP = -1
local ENV_TEMP = 21
local ROAD_TEMP_OFFSET_C = -3
local ROAD_TEMP = ENV_TEMP + ROAD_TEMP_OFFSET_C
local got_env_temp = false

local TEMP_WORK_GAIN_RATE = 1.0
local TEMP_SLIP_GAIN_RATE = 1.0
local TEMP_COOL_RATE = 1.0
local TEMP_COOL_VEL_RATE = 1.0
local TEMP_GAIN_RATE_CORE = 1.0
local WEAR_RATE = 1.0
local HOT_GRIP_LOSS_FACTOR = 1.0
local MANUAL_TYRE_PROFILE = "auto"

M._axlePressureOverride = M._axlePressureOverride or {
    frontPsi = nil, rearPsi = nil, initialFrontPsi = nil, initialRearPsi = nil
}

local TYRE_PROFILES = {
    race = {
        id = "race", label = "Race / slick", workingTemp = 100, overheatStart = 110,
        points = {
            {0, 0.86}, {20, 0.89}, {40, 0.93}, {60, 0.97}, {80, 0.99},
            {90, 1.00}, {110, 1.00}, {123, 0.985}, {137, 0.95},
            {150, 0.90}, {163, 0.82}, {177, 0.70}, {203, 0.52},
            {230, 0.42}, {310, 0.35}
        }
    },
    sport = {
        id = "sport", classId = "sport", label = "Sport / performance road", workingTemp = 65,
        overheatStart = 70, wearOverheatStart = 80,
        points = {
            -- ROAD-TYRE TEMPERATURE / GRIP CALIBRATION.
            -- [TEMP-R2][PRODUCT/CATEGORY-DERIVED] Max Performance Summer tyres such as the
            -- Michelin Pilot Sport 4S are explicitly street-focused performance tyres
            -- for sports/performance sedans, with strong warm-road dry/wet capability;
            -- they are not intended as extended-lapping/competition tyres.
            -- https://www.tirerack.com/tires/tests/testDisplay.jsp?ttid=248
            -- https://www.tirerack.com/tires/tires.jsp?tireMake=Michelin&tireModel=Pilot+Sport+4s
            -- [KTS ENGINEERING CALIBRATION] Keep Sport clearly more
            -- cold-sensitive than Standard, but much less so than Semi-Slick: 0.88 at
            -- 0 C, 0.98 at 20 C, effectively full grip by ~40 C. Grip fade begins at
            -- 70 C, builds gently for the first ~20 C, then steepens non-linearly.
            -- Catastrophic-hot residual is deliberately bounded at 0.58 by 260 C;
            -- physical wear/destruction, not this LUT, owns material failure beyond it.
            {0, 0.88}, {10, 0.94}, {20, 0.98}, {30, 0.995}, {40, 1.00},
            {50, 1.00}, {65, 1.00}, {70, 1.00}, {80, 0.995}, {90, 0.985},
            {105, 0.955}, {125, 0.915}, {150, 0.860}, {180, 0.780},
            {220, 0.670}, {260, 0.580}
        },
        shortTermOnsetC = 14.0, shortTermSaturationC = 95.0,
        shortTermMinGrip = 0.78, shortTermResponseExponent = 0.78,
    },
    semi_slick = {
        id = "sport", classId = "semi_slick", label = "Semi-Slick / track-day", workingTemp = 90, overheatStart = 105,
        points = {
            -- SPORT-PLUS-2R / CUP-2-R SEMI-SLICK TEMPERATURE / GRIP CALIBRATION.
            -- [TEMP-R3][PRODUCT-SPEC-DERIVED CLASS ANCHOR] BeamNG Sport Plus / 2R semi-slicks
            -- are treated here as road-legal track tyres in the Michelin Pilot Sport
            -- Cup 2 R class, not ordinary performance-road or generic Cup 2 tyres.
            -- Michelin specifies an optimum Cup 2 R rubber running range of 70-100 C
            -- with ~90 C ideal and describes warm-up as comparable with racing tyres.
            -- https://marketing.michelin.co.uk/p/PDF/Technical%20Bulletin_PSC2R.pdf
            -- [LITERATURE/PRODUCT-DERIVED SHAPE + KTS ENGINEERING CALIBRATION]
            -- Cold-side response is intentionally non-linear: clearly more demanding
            -- than Sport road tyres, approximately soft-slick-like around 20-60 C,
            -- but reaching peak slightly earlier because it remains road homologated.
            -- Post-105 C fade is deliberately sharper than a road tyre initially,
            -- then progressively flattens above ~200 C. At those destructive states,
            -- Cambridge wear + the destruction/ejecta energy path own much
            -- of the physical failure, so the temperature LUT should not duplicate a
            -- pure-slick collapse. 260 C / 0.56 and 310 C / 0.50 are KTS test targets.
            {0, 0.73}, {10, 0.78}, {20, 0.83}, {30, 0.87}, {40, 0.91},
            {55, 0.95}, {70, 0.985}, {80, 0.998}, {90, 1.00}, {100, 1.00},
            {105, 1.00}, {120, 0.970}, {140, 0.920}, {160, 0.855},
            {180, 0.785}, {200, 0.730}, {220, 0.665}, {240, 0.610},
            {260, 0.560}, {285, 0.530}, {310, 0.500}
        },
        shortTermOnsetC = 14.0, shortTermSaturationC = 95.0,
        shortTermMinGrip = 0.78, shortTermResponseExponent = 0.78,
    },
    standard = {
        id = "standard", label = "Standard / road", workingTemp = 50,
        overheatStart = 50, wearOverheatStart = 70,
        points = {
            -- ROAD-TYRE TEMPERATURE / GRIP CALIBRATION.
            -- [TEMP-R1][LITERATURE-DERIVED SHAPE + KTS ENGINEERING CALIBRATION] Ordinary road
            -- tread-rubber experiments support a temperature response that rises then
            -- falls rather than an artificial linear/cliff transition. Exact KTS points
            -- below are driving calibration, NOT measured universal passenger-tyre mu.
            -- https://pmc.ncbi.nlm.nih.gov/articles/PMC10934219/
            -- Rubber keeps its broad low-temperature plateau, then uses a rounded
            -- over-softening fade rather than a cliff. The first +20 C after the
            -- 50 C fade point is deliberately mild (1.000 -> 0.985); loss then grows
            -- through severe overheat and flattens toward a 0.62 residual at 250 C.
            -- The 250 C / 0.62 endpoint is a KTS driving-test target, not a claimed
            -- manufacturer datum. Physical wear/destruction owns failure beyond it.
            {0, 0.95}, {10, 0.98}, {20, 1.00}, {40, 1.00}, {50, 1.00},
            {60, 0.995}, {70, 0.985}, {85, 0.955}, {100, 0.915},
            {120, 0.855}, {145, 0.790}, {175, 0.720}, {210, 0.660},
            {250, 0.620}
        }
    },
    drift = {
        id = "drift", label = "Drift / heat-resistant", workingTemp = 90, overheatStart = 115,
        points = {
            {0, 0.90}, {20, 0.94}, {40, 0.97}, {60, 0.99}, {80, 1.00},
            {110, 1.00}, {130, 0.995}, {150, 0.985}, {180, 0.965},
            {210, 0.94}, {240, 0.91}, {280, 0.87}
        }
    }
}

M._standardRoad = {
    realisticBrushMuScaleMin = 0.70,
    structuralTempWeights = { core = 0.55, tread = 0.40, surface = 0.05 },

    corneringStiffnessTempPoints = {
        {-20, 1.00}, {0, 1.00}, {20, 1.00}, {40, 1.00}, {60, 1.00},
        {80, 1.00}, {100, 1.00}, {120, 1.00}, {150, 1.00}, {200, 1.00}
    },
}

-- Research-calibrated UHP / semi-slick family. Research refs: [R1][R5].
-- High-performance summer Flat-Trac work shows materially temperature-dependent
-- cornering stiffness, while low-profile/reinforced constructions are sharper
-- than a generic passenger tyre. Exact normalized factors remain our calibration.
M._sportSemiSlick = {
    realisticBrushMuScaleMin = 0.55,
    structuralTempWeights = { core = 0.60, tread = 0.35, surface = 0.05 },

    corneringStiffnessTempPoints = {
        {0, 1.00}, {20, 1.00}, {40, 1.00}, {60, 1.00}, {75, 1.00},
        {85, 1.00}, {105, 1.00}, {130, 1.00}, {160, 1.00}, {200, 1.00}
    },

    warmFullSlideAnchor = 0.90,
    fullSlideRatioTempPoints = {
        {0, 0.74}, {20, 0.80}, {40, 0.84}, {60, 0.875}, {75, 0.895},
        {85, 0.90}, {105, 0.90}, {130, 0.885}, {160, 0.86},
        {190, 0.83}, {230, 0.80}
    },

    --
    --
    --
    modelOwnedGripCurveEnabled = true,
}

--
M._modelOwnedGripCurve = {
    enabled = true,
    enabledByProfile = {
        standard = true,
        sport = true,
        race = true,
        rally_asphalt = true,
        rally_gravel = true,
        drift = true,
    },

    --
    maxLossByProfile = {
        standard = 0.045,
        sport = 0.060,
        race = 0.055,
        rally_asphalt = 0.055,
        rally_gravel = 0.080,
        drift = 0.025,
    },
    halfSpeedMpsByProfile = {
        standard = 5.0,
        sport = 6.0,
        race = 7.0,
        rally_asphalt = 6.5,
        rally_gravel = 4.5,
        drift = 8.0,
    },
    exponentByProfile = {
        standard = 0.85,
        sport = 0.90,
        race = 0.95,
        rally_asphalt = 0.90,
        rally_gravel = 0.85,
        drift = 0.85,
    },
    minVelocityFactorByProfile = {
        standard = 0.92,
        sport = 0.90,
        race = 0.90,
        rally_asphalt = 0.90,
        rally_gravel = 0.88,
        drift = 0.95,
    },

    downwardGateOnsetU = 1.00,
    downwardGateFullU = 1.03,
}

--
--
M._modelOwnedGripCurve.evaluatePatchRatio = function(
    profileId, slidingLoadFraction, brushUtilization, wholePatchHotFraction, slipSpeedMps,
    baseKineticRatio, nativePatchRatio)

    local cfg = M._modelOwnedGripCurve or {}
    local pid = tostring(profileId or "standard")
    local B = math.max(0, math.min(1, tonumber(slidingLoadFraction) or 0))
    local U = math.max(0, tonumber(brushUtilization) or 0)
    local Hwhole = math.max(0, math.min(B, tonumber(wholePatchHotFraction) or 0))
    local slipV = math.max(tonumber(slipSpeedMps) or 0, 0)
    local baseKinetic = math.max(0.05, math.min(1.50, tonumber(baseKineticRatio) or 1))
    local nativeRatio = math.max(0.05, math.min(2.0, tonumber(nativePatchRatio) or 1))

    local historyState = B > 1e-5 and math.max(0, math.min(1, Hwhole / B)) or 0

    local halfV = math.max(tonumber(
        cfg.halfSpeedMpsByProfile and cfg.halfSpeedMpsByProfile[pid]) or 6.0, 0.05)
    local exponent = math.max(tonumber(
        cfg.exponentByProfile and cfg.exponentByProfile[pid]) or 0.90, 0.10)
    local speedState = slipV > 0 and ((slipV / (slipV + halfV)) ^ exponent) or 0

    local maxLoss = math.max(0, math.min(0.50, tonumber(
        cfg.maxLossByProfile and cfg.maxLossByProfile[pid]) or 0.050))
    local minVelocityFactor = math.max(0.50, math.min(1.0, tonumber(
        cfg.minVelocityFactorByProfile and cfg.minVelocityFactorByProfile[pid]) or 0.90))

    local hotVelocityFactor = math.max(minVelocityFactor, 1 - maxLoss * speedState)
    local kineticVelocityFactor = 1 + (hotVelocityFactor - 1) * historyState
    local kineticRatio = math.max(0.05, math.min(baseKinetic,
        baseKinetic * kineticVelocityFactor))

    local modelPatchRatio = math.max(0.05, math.min(2.0,
        (1 - speedState) + speedState * kineticRatio))

    --
    --
    local onsetB = math.max(0, math.min(0.95,
        tonumber(M._flashMemory.mechanicalResearchOnsetB) or 0.08))
    local fullB = math.max(onsetB + 0.001, math.min(1.0,
        tonumber(M._flashMemory.mechanicalResearchFullB) or 0.30))
    local au = math.max(0, math.min(1, (B - onsetB) / (fullB - onsetB)))
    local baseAuthority = au * au * (3 - 2 * au)

    local gateOnsetU = math.max(0.50, tonumber(cfg.downwardGateOnsetU) or 1.00)
    local gateFullU = math.max(gateOnsetU + 0.001, tonumber(cfg.downwardGateFullU) or 1.03)
    local gateT = math.max(0, math.min(1, (U - gateOnsetU) / (gateFullU - gateOnsetU)))
    local downwardPeakGate = gateT * gateT * (3 - 2 * gateT)

    local correctionDirection = modelPatchRatio - nativeRatio
    local authority = correctionDirection < 0
        and (baseAuthority * downwardPeakGate)
        or baseAuthority

    local commandedPatchRatio = nativeRatio + correctionDirection * authority
    local correctionMultiplier = commandedPatchRatio / math.max(nativeRatio, 0.05)

    return {
        profileId = pid,
        slidingLoadFraction = B,
        brushUtilization = U,
        historyState = historyState,
        speedState = speedState,
        hotVelocityFactor = hotVelocityFactor,
        kineticVelocityFactor = kineticVelocityFactor,
        baseKineticRatio = baseKinetic,
        kineticRatio = kineticRatio,
        modelPatchRatio = modelPatchRatio,
        baseAuthority = baseAuthority,
        downwardPeakGate = downwardPeakGate,
        authority = authority,
        commandedPatchRatio = commandedPatchRatio,
        nativePatchRatio = nativeRatio,
        correctionMultiplier = correctionMultiplier,
    }
end

M._sportSemiSlick.getFullSlideRatio = function(temperature)
    local points = M._sportSemiSlick.fullSlideRatioTempPoints
    local temp = tonumber(temperature) or 85
    if temp <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local x1, y1 = points[i - 1][1], points[i - 1][2]
        local x2, y2 = points[i][1], points[i][2]
        if temp <= x2 then
            local t = (temp - x1) / math.max(x2 - x1, 0.000001)
            return y1 + (y2 - y1) * t
        end
    end
    return points[#points][2]
end

-- Generic research-backed slick compound family. Research refs: [R1][R5]. There is no universal
-- Soft/Medium/Hard curve across manufacturers; these are deliberately conservative
-- relative variants anchored to the current Race/slick model and to published
-- motorsport trends: softer compounds work at lower temperatures and trade life /
-- thermal stability for a small peak-performance gain, while harder compounds need
-- more temperature and retain performance for longer. The normalized temperature
-- curves are separate from the small all-grip compound multiplier below.
M._slickCompounds = {
    selected = "medium",
    structuralTempWeights = { core = 0.70, tread = 0.25, surface = 0.05 },
    coldGripRelativeScale = 0.90,
    coldGripFullPenaltyBelowC = 20.0,
    glassTransitionBlendSpanC = 20.0,
    warmFullSlideAnchor = 0.86,
    realisticBrushMuScaleMin = 0.45,
    variants = {
        supersoft = {
            id = "supersoft", label = "Super Soft", gripMultiplier = 1.05, wearMultiplier = 2.00,
            bulkTgC = -25.0, dynamicGlassKneeC = 5.0, glassPeakMinScale = 0.86,
            fullSlideRatioTempPoints = {
                {-20, 0.58}, {-10, 0.67}, {0, 0.76}, {10, 0.80}, {20, 0.82}, {85, 0.86}
            },
            corneringStiffnessTempPoints = {
                {-30, 1.35}, {-20, 1.28}, {-10, 1.21}, {0, 1.15}, {20, 1.12}, {40, 1.08}, {60, 1.04}, {75, 1.01},
                {85, 1.00}, {100, 0.97}, {125, 0.92}, {160, 0.88}
            },
            profile = {
                id = "race", label = "Race / slick — Super Soft", workingTemp = 85, overheatStart = 105,
                points = {
                    {0, 0.79}, {20, 0.87}, {40, 0.93}, {60, 0.975}, {75, 0.997},
                    {80, 1.00}, {100, 1.00}, {105, 0.99}, {119, 0.93}, {134, 0.84},
                    {155, 0.69}, {184, 0.53}, {220, 0.42}, {270, 0.35}
                },
                shortTermOnsetC = 12.0, shortTermSaturationC = 82.0,
                shortTermMinGrip = 0.75, shortTermResponseExponent = 0.75,
            },
        },
        soft = {
            id = "soft", label = "Soft", gripMultiplier = 1.03, wearMultiplier = 1.55,
            bulkTgC = -20.0, dynamicGlassKneeC = 10.0, glassPeakMinScale = 0.82,
            fullSlideRatioTempPoints = {
                {-20, 0.46}, {-10, 0.58}, {0, 0.70}, {10, 0.76}, {20, 0.79}, {95, 0.86}
            },
            corneringStiffnessTempPoints = {
                {-30, 1.50}, {-20, 1.40}, {-10, 1.30}, {0, 1.22}, {20, 1.18}, {40, 1.12}, {60, 1.07}, {80, 1.03},
                {95, 1.00}, {115, 0.97}, {140, 0.93}, {180, 0.90}
            },
            profile = {
                id = "race", label = "Race / slick — Soft", workingTemp = 95, overheatStart = 115,
                points = {
                    {0, 0.72}, {20, 0.82}, {40, 0.90}, {60, 0.96}, {75, 0.985},
                    {85, 0.997}, {90, 1.00}, {110, 1.00}, {115, 0.99}, {128, 0.94},
                    {142, 0.86}, {155, 0.75}, {176, 0.60}, {202, 0.47}, {256, 0.38}, {310, 0.34}
                },
                shortTermOnsetC = 15.0, shortTermSaturationC = 95.0,
                shortTermMinGrip = 0.78, shortTermResponseExponent = 0.78,
            },
        },
        medium = {
            id = "medium", label = "Medium", gripMultiplier = 1.00, wearMultiplier = 1.00,
            bulkTgC = -15.0, dynamicGlassKneeC = 15.0, glassPeakMinScale = 0.76,
            fullSlideRatioTempPoints = {
                {-20, 0.36}, {-10, 0.48}, {0, 0.61}, {10, 0.70}, {20, 0.75}, {105, 0.86}
            },
            corneringStiffnessTempPoints = {
                {-30, 1.65}, {-20, 1.58}, {-10, 1.46}, {0, 1.34}, {20, 1.27}, {40, 1.20}, {60, 1.13}, {80, 1.06},
                {100, 1.01}, {105, 1.00}, {130, 0.96}, {160, 0.91}, {200, 0.89}
            },
            profile = {
                id = "race", label = "Race / slick — Medium", workingTemp = 105, overheatStart = 130,
                points = {
                    {0, 0.56}, {20, 0.68}, {40, 0.78}, {60, 0.87}, {80, 0.94},
                    {95, 0.985}, {100, 1.00}, {125, 1.00}, {130, 0.99}, {143, 0.95},
                    {157, 0.89}, {177, 0.78}, {197, 0.65}, {223, 0.52}, {277, 0.40}, {330, 0.34}
                },
                shortTermOnsetC = 18.0, shortTermSaturationC = 115.0,
                shortTermMinGrip = 0.82, shortTermResponseExponent = 0.80,
            },
        },
        hard = {
            id = "hard", label = "Hard", gripMultiplier = 0.98, wearMultiplier = 0.80,
            bulkTgC = -10.0, dynamicGlassKneeC = 20.0, glassPeakMinScale = 0.70,
            fullSlideRatioTempPoints = {
                {-20, 0.30}, {-10, 0.40}, {0, 0.53}, {10, 0.64}, {20, 0.72}, {115, 0.86}
            },
            corneringStiffnessTempPoints = {
                {-30, 1.80}, {-20, 1.70}, {-10, 1.58}, {0, 1.42}, {20, 1.35}, {40, 1.27}, {60, 1.19}, {80, 1.12},
                {100, 1.05}, {115, 1.00}, {140, 0.96}, {180, 0.91}, {220, 0.89}
            },
            profile = {
                id = "race", label = "Race / slick — Hard", workingTemp = 115, overheatStart = 140,
                points = {
                    {0, 0.50}, {20, 0.62}, {40, 0.72}, {60, 0.82}, {80, 0.90},
                    {100, 0.97}, {110, 1.00}, {135, 1.00}, {140, 0.995}, {153, 0.97},
                    {173, 0.92}, {192, 0.84}, {219, 0.72}, {252, 0.58}, {298, 0.44}, {350, 0.36}
                },
                shortTermOnsetC = 22.0, shortTermSaturationC = 135.0,
                shortTermMinGrip = 0.86, shortTermResponseExponent = 0.84,
            },
        },
    },
}

M._rallyCompounds = {
    selectedSurface = "asphalt",
    selectedCompound = "medium",
    surfaces = {
        asphalt = {
            id = "asphalt", label = "Asphalt", profileId = "rally_asphalt",
            roadPeakMultiplier = 1.00,
            structuralTempWeights = { core = 0.65, tread = 0.30, surface = 0.05 },
            realisticBrushMuScaleMin = 0.55,
            variants = {
                supersoft = {
                    id = "supersoft", label = "Super Soft", gripMultiplier = 1.000, wearMultiplier = 1.45,
                    corneringStiffnessTempPoints = {
                        {0, 1.15}, {20, 1.11}, {35, 1.05}, {45, 1.00},
                        {60, 0.97}, {85, 0.92}, {120, 0.89}
                    },
                    profile = {
                        id = "rally_asphalt", label = "Rally / Asphalt — Super Soft", workingTemp = 45, overheatStart = 60,
                        points = {
                            {0, 0.76}, {20, 0.86}, {35, 0.96}, {45, 1.00}, {58, 1.00},
                            {67, 0.96}, {81, 0.86}, {102, 0.68}, {131, 0.50}, {173, 0.38}, {230, 0.32}
                        },
                        shortTermOnsetC = 10.0, shortTermSaturationC = 65.0,
                        shortTermMinGrip = 0.74, shortTermResponseExponent = 0.72,
                    },
                },
                soft = {
                    id = "soft", label = "Soft", gripMultiplier = 1.000, wearMultiplier = 1.22,
                    corneringStiffnessTempPoints = {
                        {0, 1.22}, {20, 1.17}, {40, 1.09}, {60, 1.00},
                        {80, 0.97}, {110, 0.92}, {150, 0.89}
                    },
                    profile = {
                        id = "rally_asphalt", label = "Rally / Asphalt — Soft", workingTemp = 60, overheatStart = 78,
                        points = {
                            {0, 0.68}, {20, 0.80}, {40, 0.91}, {52, 0.98}, {58, 1.00},
                            {74, 1.00}, {81, 0.98}, {98, 0.90}, {120, 0.76}, {150, 0.57}, {199, 0.41}, {255, 0.34}
                        },
                        shortTermOnsetC = 12.0, shortTermSaturationC = 80.0,
                        shortTermMinGrip = 0.77, shortTermResponseExponent = 0.75,
                    },
                },
                medium = {
                    id = "medium", label = "Medium", gripMultiplier = 1.000, wearMultiplier = 1.00,
                    corneringStiffnessTempPoints = {
                        {0, 1.31}, {20, 1.25}, {40, 1.17}, {60, 1.09}, {80, 1.00},
                        {105, 0.97}, {140, 0.92}, {180, 0.89}
                    },
                    profile = {
                        id = "rally_asphalt", label = "Rally / Asphalt — Medium", workingTemp = 80, overheatStart = 100,
                        points = {
                            {0, 0.60}, {20, 0.72}, {40, 0.83}, {60, 0.93}, {72, 0.985},
                            {78, 1.00}, {96, 1.00}, {103, 0.985}, {122, 0.91}, {148, 0.79},
                            {182, 0.62}, {230, 0.46}, {285, 0.36}
                        },
                        shortTermOnsetC = 15.0, shortTermSaturationC = 100.0,
                        shortTermMinGrip = 0.80, shortTermResponseExponent = 0.78,
                    },
                },
                hard = {
                    id = "hard", label = "Hard", gripMultiplier = 1.000, wearMultiplier = 0.76,
                    corneringStiffnessTempPoints = {
                        {0, 1.39}, {20, 1.33}, {40, 1.25}, {60, 1.17}, {80, 1.09},
                        {100, 1.00}, {130, 0.96}, {170, 0.91}, {215, 0.89}
                    },
                    profile = {
                        id = "rally_asphalt", label = "Rally / Asphalt — Hard", workingTemp = 100, overheatStart = 130,
                        points = {
                            {0, 0.53}, {20, 0.64}, {40, 0.75}, {60, 0.85}, {80, 0.94},
                            {94, 0.99}, {100, 1.00}, {126, 1.00}, {133, 0.99}, {156, 0.94},
                            {190, 0.84}, {229, 0.70}, {275, 0.55}, {335, 0.42}
                        },
                        shortTermOnsetC = 19.0, shortTermSaturationC = 125.0,
                        shortTermMinGrip = 0.84, shortTermResponseExponent = 0.82,
                    },
                },
            },
        },
        gravel = {
            id = "gravel", label = "Gravel", profileId = "rally_gravel",
            roadPeakMultiplier = 1.08,
            structuralTempWeights = { core = 0.45, tread = 0.50, surface = 0.05 },
            realisticBrushMuScaleMin = 0.60,
            variants = {
                supersoft = {
                    id = "supersoft", label = "Super Soft", gripMultiplier = 1.000, wearMultiplier = 1.50,
                    corneringStiffnessTempPoints = {
                        {0, 1.10}, {20, 1.07}, {35, 1.03}, {45, 1.00},
                        {65, 0.96}, {95, 0.91}, {135, 0.88}
                    },
                    profile = {
                        id = "rally_gravel", label = "Rally / Gravel — Super Soft", workingTemp = 45, overheatStart = 65,
                        points = {
                            {0, 0.78}, {20, 0.88}, {35, 0.97}, {45, 1.00}, {62, 1.00},
                            {72, 0.96}, {88, 0.87}, {112, 0.71}, {146, 0.53}, {194, 0.40}, {255, 0.33}
                        },
                        shortTermOnsetC = 11.0, shortTermSaturationC = 72.0,
                        shortTermMinGrip = 0.76, shortTermResponseExponent = 0.73,
                    },
                },
                soft = {
                    id = "soft", label = "Soft", gripMultiplier = 1.000, wearMultiplier = 1.25,
                    corneringStiffnessTempPoints = {
                        {0, 1.16}, {20, 1.13}, {40, 1.08}, {60, 1.03}, {75, 1.00},
                        {105, 0.95}, {145, 0.90}, {190, 0.88}
                    },
                    profile = {
                        id = "rally_gravel", label = "Rally / Gravel — Soft", workingTemp = 75, overheatStart = 105,
                        points = {
                            {0, 0.68}, {20, 0.79}, {40, 0.89}, {55, 0.96}, {68, 0.995},
                            {75, 1.00}, {100, 1.00}, {108, 0.985}, {127, 0.92}, {158, 0.80},
                            {198, 0.63}, {250, 0.47}, {310, 0.37}
                        },
                        shortTermOnsetC = 15.0, shortTermSaturationC = 105.0,
                        shortTermMinGrip = 0.80, shortTermResponseExponent = 0.77,
                    },
                },
                medium = {
                    id = "medium", label = "Medium", gripMultiplier = 1.000, wearMultiplier = 1.00,
                    corneringStiffnessTempPoints = {
                        {0, 1.24}, {20, 1.20}, {40, 1.15}, {60, 1.09}, {80, 1.04},
                        {100, 1.00}, {130, 0.96}, {170, 0.91}, {215, 0.88}
                    },
                    profile = {
                        id = "rally_gravel", label = "Rally / Gravel — Medium", workingTemp = 100, overheatStart = 130,
                        points = {
                            {0, 0.60}, {20, 0.71}, {40, 0.81}, {60, 0.89}, {80, 0.96},
                            {94, 0.995}, {100, 1.00}, {126, 1.00}, {133, 0.99}, {156, 0.94},
                            {190, 0.84}, {229, 0.70}, {275, 0.55}, {335, 0.42}
                        },
                        shortTermOnsetC = 18.0, shortTermSaturationC = 125.0,
                        shortTermMinGrip = 0.83, shortTermResponseExponent = 0.80,
                    },
                },
                hard = {
                    id = "hard", label = "Hard", gripMultiplier = 1.000, wearMultiplier = 0.78,
                    corneringStiffnessTempPoints = {
                        {0, 1.30}, {20, 1.27}, {40, 1.21}, {60, 1.16}, {80, 1.10},
                        {100, 1.04}, {110, 1.00}, {140, 0.96}, {185, 0.91}, {230, 0.88}
                    },
                    profile = {
                        id = "rally_gravel", label = "Rally / Gravel — Hard", workingTemp = 110, overheatStart = 140,
                        points = {
                            {0, 0.55}, {20, 0.65}, {40, 0.75}, {60, 0.84}, {80, 0.92},
                            {100, 0.985}, {108, 1.00}, {136, 1.00}, {142, 0.99}, {165, 0.95},
                            {196, 0.87}, {234, 0.75}, {278, 0.61}, {334, 0.47}, {390, 0.38}
                        },
                        shortTermOnsetC = 21.0, shortTermSaturationC = 140.0,
                        shortTermMinGrip = 0.86, shortTermResponseExponent = 0.84,
                    },
                },
            },
        },
    },
}

-- Rally dirt overlay. BeamNG remains the owner of the contacted ground
-- model (soil depth, roughness, sinkage, static/sliding friction and terrain
-- particle behaviour). This table owns only the rally-tyre state layered on top:
-- heat retained by the rubber, a deliberately flat <=1.00 dirt temperature
-- response, tread-block height and the four signed biting faces of each block.
--
-- The coefficients are transparent first-pass calibration targets. They encode
-- the direction established by rally-tyre literature and field observations, not
-- manufacturer force-test data. Keeping the whole subsystem on M also avoids the
-- LuaJIT main-chunk local-variable ceiling in this very large extension.
M._rallyDirt = {
    enabled = true,
    modelVersion = "v1.4.2-exclusive-dirt-directional-blocks",
    roadClass = "road",
    defaultDirtClass = "dirt",
    materialClassCache = {},
    wheelRouteClass = {},
    wheelMaterialSignature = {},
    physicsRouteChanges = 0,
    edgeReferenceWearDepthM = 0.0105,
    surfaces = {
        mud = {
            label = "Mud", priority = 5,
            slipHeatScale = 0.20, flexHeatScale = 0.75,
            heightWearScale = 0.08, edgeWearScale = 0.12,
            fastHeatAuthority = 0.00,
            coldGrip = 0.98, hot60Grip = 0.98, hot130Grip = 0.93,
            hotWear60 = 1.02, hotWear130 = 1.10,
            gripFloor = 0.35, heightAuthority = 0.50, edgeAuthority = 0.15,
        },
        dirt = {
            label = "Dirt / sand", priority = 2,
            slipHeatScale = 0.35, flexHeatScale = 1.00,
            heightWearScale = 0.30, edgeWearScale = 0.55,
            fastHeatAuthority = 0.05,
            coldGrip = 0.97, hot60Grip = 0.96, hot130Grip = 0.88,
            hotWear60 = 1.08, hotWear130 = 1.25,
            gripFloor = 0.42, heightAuthority = 0.38, edgeAuthority = 0.20,
        },
        loose_gravel = {
            label = "Loose gravel", priority = 4,
            slipHeatScale = 0.55, flexHeatScale = 1.15,
            heightWearScale = 0.65, edgeWearScale = 1.00,
            fastHeatAuthority = 0.10,
            coldGrip = 0.96, hot60Grip = 0.94, hot130Grip = 0.84,
            hotWear60 = 1.12, hotWear130 = 1.40,
            gripFloor = 0.46, heightAuthority = 0.29, edgeAuthority = 0.25,
        },
        packed_gravel = {
            label = "Packed / rocky gravel", priority = 3,
            slipHeatScale = 0.75, flexHeatScale = 1.25,
            heightWearScale = 1.00, edgeWearScale = 0.75,
            fastHeatAuthority = 0.20,
            coldGrip = 0.94, hot60Grip = 0.91, hot130Grip = 0.77,
            hotWear60 = 1.18, hotWear130 = 1.55,
            gripFloor = 0.58, heightAuthority = 0.17, edgeAuthority = 0.25,
        },
    },
    compoundWindows = {
        supersoft = {20, 60},
        soft = {50, 90},
        medium = {70, 130},
        hard = {90, 150},
    },
}

TYRE_PROFILES.rally_asphalt = M._rallyCompounds.surfaces.asphalt.variants.medium.profile
TYRE_PROFILES.rally_gravel = M._rallyCompounds.surfaces.gravel.variants.medium.profile

-- Research-calibrated thermal material/geometry parameters. Research refs: [R5][R12][R13].
-- Keep the entire model under one M table so this large Vehicle-Lua extension does
-- not exceed Lua's main-chunk local-variable limit.
--
-- TREAD-GEOMETRY PROVENANCE CATALOG
-- The tags below deliberately distinguish measured/regulatory data from KTS engineering defaults.
-- Preserve these provenance tags so calibrated values are not silently replaced by
-- incompatible assumptions during future maintenance.
--
-- [TG-R1][MEASURED] Modern summer passenger tyres: mean footprint void surface = 34.8%.
-- https://www.mdpi.com/2624-8921/7/3/91
-- [TG-R2][PRODUCT SPEC] Michelin Pilot Sport 4S Max Performance Summer reference: common
-- non-OE sizes are 9.5/32 in = 7.54 mm new tread depth (e.g. 225/45ZR17, 245/40ZR17).
-- https://www.tirerack.com/tires/Spec.jsp?partnum=54YR1PS4SXL&tireMake=Michelin&tireModel=Pilot+Sport+4s
-- [TG-R3][PRODUCT SPEC] Toyo Proxes R888R track/semi-slick: new tread depth = 6.3/32 in ~= 5.0 mm.
-- https://www.tirerack.com/tires/Spec.jsp?partnum=54WR7R888RXL&tireMake=Toyo&tireModel=Proxes+R888R
-- [TG-R13][PRODUCT SPEC] Michelin Pilot Sport 4 performance-road reference: common sizes such as
-- 225/40ZR18 and 235/40ZR18 are 9.5/32 in = 7.54 mm new tread depth.
-- https://www.tirerack.com/tires/Spec.jsp?partnum=14YR8PS4&tireMake=Michelin&tireModel=Pilot+Sport+4
-- [TG-R14][PRODUCT SPEC / WEAR-CLASS ANCHOR] Michelin Pilot Sport Cup 2 R is a road-legal
-- extreme-track tyre with UTQG 140 and 5.5/32 in tread; Hoosier R7 race tyre is UTQG 40 and
-- 4/32 in. These ratings are NOT converted numerically into KTS K1; they only support giving
-- Sport Plus 2R / Semi its own abrasion class between road-UHP and dedicated race rubber.
-- https://www.tirerack.com/tires/Spec.jsp?partnum=33YR0PSC2RXLV2&tireMake=Michelin&tireModel=Pilot+Sport+Cup+2+R
-- https://www.tirerack.com/tires/Spec.jsp?partnum=24ZR8R7&tireMake=Hoosier&tireModel=R7
-- [TG-R4][REGULATORY+HOMOLOGATION] FIA asphalt rally: >=17% area at >=5.5 mm depth and >=21.5%
-- at >=1.8 mm; current homologated patterns commonly measure about 17.8-20.1% deep and
-- 21.5-24.4% shallow. These are strong anchors for a NON-collapsing groove taper.
-- https://www.fia.com/regulation/category/119
-- https://api.fia.com/system/files/documents/2026-03-16_tyre_catalogue_0.pdf
-- [TG-R5][REGULATORY] WRC gravel grooving rate must exceed 25% (non-homologated gravel route).
-- https://www.fia.com/system/files/documents/2026_wrc_sr_2026_published_25_november_2025.pdf
-- [TG-R6][GEOMETRY/PATENT] Real tread groove walls use finite draft, commonly ~5-20 deg in preferred
-- embodiments; grooves therefore remain materially open near the floor rather than tapering to ~0.
-- https://patents.google.com/patent/EP2860048A1/en
-- [TG-R7][PASSENGER-TYRE CONSTRUCTION] Main grooves commonly 6-8 mm; rubber below groove floor to
-- outer belt <=2.5 mm, preferably ~1-2 mm; undertread layer itself ~0.5-1.5 mm.
-- https://patents.google.com/patent/JP3354654B2/en
-- [TG-R8][MATERIAL, MEASURED] Q134 tread compound: k=0.235 W/(m K), cp=1.591 kJ/(kg K), rho=1.125 g/cm3.
-- These are SOLID-RUBBER material properties and contain no tread-groove geometry correction.
-- https://pmc.ncbi.nlm.nih.gov/articles/PMC10756965/
-- [TG-R9][MATERIAL, MEASURED] Vulcanized S-SBR specimen: k=0.282 W/(m K), cp=1741 J/(kg K).
-- Again this is solid-compound laboratory data, not an effective grooved-tread conductivity.
-- https://www.mdpi.com/2073-4360/14/11/2210
-- [TG-R10][MATERIAL RANGE] Carbon-black-filled rubber compounds commonly span roughly 0.2-0.4 W/(m K).
-- https://www.sciencedirect.com/science/article/pii/S0142941818312558
-- [TG-R11][LITERATURE, ROUGH-CONTACT HEAT TRANSFER] Thermal contact conductance commonly follows a
-- sub-linear pressure power law; exponents around 0.5-0.6 are reported for some rough-contact regimes.
-- This is NOT a tyre-road-specific measured exponent, but it supports partial pressure compensation rather
-- than either zero compensation or full area cancellation.
-- https://www.sciencedirect.com/science/article/pii/S0017931011003334
-- [TG-R12][DIRECT TYRE HEAT-DISSIPATION DESIGN EVIDENCE] Bridgestone documents tread-groove airflow /
-- groove-wall heat dissipation as a real tread-cooling mechanism; effectiveness depends strongly on groove
-- geometry and air inflow, so KTS keeps a conservative effectiveness factor instead of treating groove walls
-- as fully free-stream-exposed.
-- https://patents.google.com/patent/US20140224395A1/en
--
-- [TG-E1][KTS ENGINEERING DEFAULT] Road-family groove-floor voids (35->20, 27->16, 18->12%) are
-- representative reduced-order tapers constrained by [TG-R6], NOT claimed universal measured class values.
-- [TG-E2][KTS ENGINEERING DEFAULT] 1.0 mm post-groove abradable cap + 0.5 mm protected solver reserve.
-- The combined 1.5 mm under-groove scale is supported by [TG-R7]; the split is a KTS modelling choice.
-- [TG-E3][KTS RESEARCH-GUIDED ENGINEERING DEFAULT] Road groove-airflow effectiveness = 0.40. Groove wall
-- area is geometry-derived and wear-dependent; 0.40 remains deliberately below full free-stream exposure
-- because [TG-R12] shows strong geometry dependence rather than a universal coefficient.
-- [TG-E7][KTS RESEARCH-GUIDED ENGINEERING DEFAULT] Road-family hard-ground conductance uses a pressure
-- compensation exponent beta=0.50: G/Gsolid = land^(1-beta) = sqrt(land). [TG-R11] supports sub-linear
-- pressure dependence but does NOT establish beta=0.50 specifically for rubber/asphalt; this is an explicit
-- reduced-order KTS default. It is applied only to Standard/Sport/Semi physical road-family profiles.
-- [TG-E8][KTS NUMERICAL / GEOMETRY DEFAULT] The last 0.25 mm of active road-family groove depth smoothly
-- closes the finite-width groove floor to zero plan void. Real groove roots are rounded/irregular rather than
-- an ideal flat-bottom discontinuity; this blend prevents an unphysical one-frame road-conductance jump when
-- the idealized groove floor is finally abraded. It changes geometry only, not rubber material properties.
-- [TG-E4][KTS RESEARCH-GUIDED INTERPOLATION] Sport k=0.245 and Semi k=0.260 W/(m K) are representative
-- solid-compound values bracketed by [TG-R8,R9,R10]; they are NOT measured universal class constants and
-- contain NO groove/air correction. Their rho/cp values remain the existing KTS class interpolations.
-- [TG-E5][KTS ENGINEERING DEFAULT] Rally-Asphalt groove-airflow effectiveness remains its existing 0.35
-- calibration and is NOT automatically inherited from the new 0.40 road-family value; Gravel keeps its
-- separately calibrated 0.55. These rally boundaries remain isolated from the road-family calibration.
-- [TG-E6][KTS REDUCED-ORDER GEOMETRY] 10 mm road/asphalt representative groove width converts plan void area
-- into aggregate groove-wall length; it is NOT a claim that every real groove is 10 mm wide. Gravel keeps its
-- existing 12 mm calibration. Combined with the selected floor ratios it yields ~11-19 deg wall draft [TG-R6].
M._physicalThermal = {
    profiles = {
        standard = {
            -- [TG-R13,R7][TG-E1,E2] Michelin Pilot Sport 4 reference: 7.5 mm fresh groove
            -- + 1.0 mm post-groove wearable rubber + 0.5 mm reserve = 9.0 mm explicit tread rubber.
            -- 35% fresh surface void remains the measured passenger-summer class anchor [TG-R1].
            treadDepthM = 0.0090, legacyTreadDepthM = 0.0080, freshGrooveDepthM = 0.0075,
            postGrooveWearableM = 0.0010, structuralReserveM = 0.0005,
            treadVoidRatio = 0.35, grooveFloorVoidRatio = 0.20,
            representativeGrooveWidthM = 0.0100, grooveAirflowEffectiveness = 0.40,
            roadGroundContactPressureExponent = 0.50, grooveClosureBlendM = 0.00025,
            grooveSidewallAreaScale = 1.00, grooveForcedConvectionSpeedCapMps = 166.6666667,
            rollingResistanceCoeff = 0.0120,
            slipHeatPartition = 0.30, deformationScale = 1.00,
            skinCoreConductance = 75.0, brakeConductance = 0.0,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.235, rubberDensity = 1125.0, rubberCp = 1590.0,
            materialProvenance = "measured-radial-tread-anchor[TG-R8]", materialConfidence = "measured-anchor",
            geometryProvenance = "TG-R13 Michelin PS4 tread-depth anchor + TG-R1 void anchor + TG-R7; TG-E1/E2 under-groove split",
            geometryConfidence = "mixed-measured-engineering",
        },
        sport = {
            -- [TG-R2,R6,R7][TG-E1,E2] Michelin Pilot Sport 4S reference: 7.5 mm fresh groove
            -- + 1.0 mm post-groove wearable rubber + 0.5 mm reserve = 9.0 mm explicit tread rubber.
            treadDepthM = 0.0090, legacyTreadDepthM = 0.0065, freshGrooveDepthM = 0.0075,
            postGrooveWearableM = 0.0010, structuralReserveM = 0.0005,
            treadVoidRatio = 0.27, grooveFloorVoidRatio = 0.16,
            representativeGrooveWidthM = 0.0100, grooveAirflowEffectiveness = 0.40,
            roadGroundContactPressureExponent = 0.50, grooveClosureBlendM = 0.00025,
            grooveSidewallAreaScale = 1.00, grooveForcedConvectionSpeedCapMps = 166.6666667,
            rollingResistanceCoeff = 0.013125,
            slipHeatPartition = 0.34, deformationScale = 1.05,
            skinCoreConductance = 80.0, brakeConductance = 0.0,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.245, rubberDensity = 1130.0, rubberCp = 1750.0,
            materialProvenance = "road-UHP-interpolation", materialConfidence = "research-guided-assumption",
            geometryProvenance = "TG-R2 Michelin PS4S tread-depth anchor + TG-R6/R7; TG-E1/E2 UHP geometry",
            geometryConfidence = "research-guided-engineering",
        },
        semi_slick = {
            -- [TG-R3,R6,R7][TG-E1,E2] Track-day/semi target: ~5.0 mm groove inside 6.5 mm total rubber.
            -- Total thickness is unchanged from the legacy 6.5 mm KTS model, so NO extra core mass is carved out.
            treadDepthM = 0.0065, legacyTreadDepthM = 0.0065, freshGrooveDepthM = 0.0050,
            postGrooveWearableM = 0.0010, structuralReserveM = 0.0005,
            treadVoidRatio = 0.18, grooveFloorVoidRatio = 0.12,
            -- asymmetric Cup-2-R cooling map (zones = outer/middle/inner).
            -- [ASYM-R1][PRODUCT-DIRECT] Tire Rack describes Pilot Sport Cup 2 R as having a massive
            -- outboard shoulder with fewer lateral notches / narrower circumferential grooves, while
            -- the inner shoulder carries deep lateral notches for water evacuation.
            -- https://www.tirerack.com/tires/tires.jsp?tireMake=Michelin&tireModel=Pilot+Sport+Cup+2+R
            -- [ASYM-R2][DIRECT HEAT-DISSIPATION EVIDENCE] Bridgestone documents tread-groove airflow
            -- as a real tread heat-dissipation mechanism; groove geometry controls the air inflow.
            -- https://patents.google.com/patent/US20140224395A1/en
            -- [ASYM-E1][KTS ENGINEERING REDUCED-ORDER MAP] The exact 12/17/25% fresh and 8/11/17%
            -- floor zone voids are NOT measured Michelin sectional values. Their equal-zone averages
            -- remain exactly the established Semi values (18% fresh / 12% floor), so they redistribute
            -- O/M/I boundary cooling without changing the tyre-wide groove/thermal-mass calibration.
            coolingZoneFreshVoidRatios = {0.12, 0.17, 0.25},
            coolingZoneFloorVoidRatios = {0.08, 0.11, 0.17},
            representativeGrooveWidthM = 0.0100, grooveAirflowEffectiveness = 0.40,
            roadGroundContactPressureExponent = 0.50, grooveClosureBlendM = 0.00025,
            grooveSidewallAreaScale = 1.00, grooveForcedConvectionSpeedCapMps = 166.6666667,
            rollingResistanceCoeff = 0.013125,
            slipHeatPartition = 0.34, deformationScale = 1.05,
            skinCoreConductance = 80.0, brakeConductance = 0.0,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.260, rubberDensity = 1135.0, rubberCp = 1900.0,
            materialProvenance = "track-day-interpolation", materialConfidence = "research-guided-assumption",
            geometryProvenance = "TG-R3+TG-R6/R7 constrained; TG-E1/E2 semi-slick geometry",
            geometryConfidence = "research-guided-engineering",
        },
        race = {
            treadDepthM = 0.0045, legacyTreadDepthM = 0.0045, structuralReserveM = 0.0005,
            rollingResistanceCoeff = 0.012075,
            slipHeatPartition = 0.56, deformationScale = 1.08,
            skinCoreConductance = 140.0, brakeConductance = 0.0, coreCapacityScale = 1.20,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.280, rubberDensity = 1140.0, rubberCp = 2070.0,
            materialProvenance = "small-racing-tyre-cp-anchor-high-k-assumption", materialConfidence = "mixed-anchor-assumption",
        },
        rally_asphalt = {
            -- [TG-R4,R6][TG-E2] FIA dry-asphalt anchor: >=17% deep void at >=5.5 mm and >=21.5% shallow.
            -- Use 23% opening -> 18% floor, 5.5 mm groove + 1.0 mm post-groove + 0.5 mm reserve.
            treadDepthM = 0.0070, legacyTreadDepthM = 0.0055, freshGrooveDepthM = 0.0055,
            postGrooveWearableM = 0.0010, structuralReserveM = 0.0005,
            treadVoidRatio = 0.23, grooveFloorVoidRatio = 0.18,
            representativeGrooveWidthM = 0.0100, grooveAirflowEffectiveness = 0.35,
            grooveSidewallAreaScale = 1.00, grooveForcedConvectionSpeedCapMps = 166.6666667,
            rollingResistanceCoeff = 0.0135,
            slipHeatPartition = 0.44, deformationScale = 1.10,
            skinCoreConductance = 105.0, brakeConductance = 0.0, coreCapacityScale = 1.08,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.250, rubberDensity = 1140.0, rubberCp = 1800.0,
            materialProvenance = "performance-tread-interpolation", materialConfidence = "research-guided-assumption",
            geometryProvenance = "TG-R4 FIA deep/shallow groove-area anchors; TG-E2 under-groove split",
            geometryConfidence = "regulatory-anchored-engineering",
        },
        rally_gravel = {
            -- [TG-R5,R6][TG-E1/E2] Preserve the validated 11 mm total package and 28% opening,
            -- but stop treating all 11 mm as uniformly 28% void. Grooves taper 28% -> 18% over 9.5 mm,
            -- leaving 1.0 mm post-groove rubber + 0.5 mm protected reserve.
            treadDepthM = 0.0110, legacyTreadDepthM = 0.0110, freshGrooveDepthM = 0.0095,
            postGrooveWearableM = 0.0010, structuralReserveM = 0.0005,
            treadVoidRatio = 0.28, grooveFloorVoidRatio = 0.18,
            rollingResistanceCoeff = 0.02345,
            slipHeatPartition = 0.36, deformationScale = 1.50,
            skinCoreConductance = 88.0, brakeConductance = 0.0, coreCapacityScale = 1.15,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.235, rubberDensity = 1160.0, rubberCp = 1750.0,
            materialProvenance = "thick-open-tread-assumption", materialConfidence = "research-guided-assumption",
            representativeGrooveWidthM = 0.0120,
            grooveAirflowEffectiveness = 0.55,
            grooveSidewallAreaScale = 1.00,
            grooveForcedConvectionSpeedCapMps = 166.6666667,
            geometryProvenance = "TG-R5 >25% gravel grooving + TG-R6 taper constraint; existing KTS 28% opening retained",
            geometryConfidence = "regulatory-anchored-engineering",
        },
        drift = {
            treadDepthM = 0.0060, legacyTreadDepthM = 0.0060, structuralReserveM = 0.0005,
            rollingResistanceCoeff = 0.01365,
            slipHeatPartition = 0.34, deformationScale = 1.05,
            skinCoreConductance = 75.0, brakeConductance = 0.0,
            gripDepthDecayM = 0.00065,
            rubberConductivity = 0.245, rubberDensity = 1135.0, rubberCp = 1850.0,
            materialProvenance = "performance-road-heat-duty-assumption", materialConfidence = "research-guided-assumption",
        },
    },
    rubberDensity = 1100.0,
    rubberCp = 1900.0,
    rubberConductivity = 0.25,
    surfaceSlipLocalizationLengthM = 0.0030,
    surfaceSlipLocalizationMinShare = 0.55,
    stefanBoltzmann = 5.670374419e-8,
    emissivity = 0.92,
    referenceTreadArea = 0.5287,
    thinSurfaceDepthM = 0.00028,
    minThinSurfaceCapacity = 165.0,
    minSkinCapacity = 3000.0,
    minCoreCapacity = 10000.0,
    maxThinSurfaceTemp = 220.0,
    maxSkinTemp = 260.0,
    maxCoreTemp = 220.0,
    maxFlashTemp = 650.0,
    maxFlashDelta = 430.0,

    maxAirTemp = 180.0,
    wheelCavity = {
        airCvJkgK = 718.0,
        airGasConstantJkgK = 287.05,
        cavityWidthFraction = 0.80,
        cavityHeightFraction = 0.70,
        minimumGasCapacityJPerK = 5.0,
        maximumGasCapacityJPerK = 5000.0,
        thermalUpdateIntervalS = 0.20,
        thermalPressureMinApplyPsi = 0.01,
        thermalMaxCatchupS = 0.60,

        rimNaturalConductanceWPerK = 5.5,
        rimTurbulenceConductancePerSqrtMS = 1.65,

        -- explicit sidewall + cavity network. The existing temp[4] core is
        -- already the effective cavity-facing carcass/liner reservoir, so there is NO
        -- extra liner RC node between core and gas. Footprint/peristaltic cavity flow is
        -- load/pressure dependent; measured peak cavity speeds can approach ~30% road speed.
        -- [R14,R15] Loaded rotating tyres do not contain stagnant air. Footprint
        -- pumping and rotation create persistent internal circulation; measured local
        -- cavity speeds can reach ~30% of road speed. 0.16 is a mean-flow ROM anchor,
        -- not a claim that the whole cavity moves at 16% of road speed.
        cavityNominalFlowFraction = 0.16,
        cavityMinFlowFraction = 0.06,
        cavityMaxFlowFraction = 0.30,
        cavityLoadFlowExponent = 0.55,
        cavityPressureFlowExponent = 0.65,

        -- Cavity-facing crown/inner-liner convection. The explicit flow model remains,
        -- but [R14] reports that internal heat-transfer coefficients can be comparable
        -- with the outside surface and [R15] finds a strong wheel-speed dependence.
        -- Therefore the liner boundary receives a conservative speed-dependent floor
        -- equal to KTS's existing external-tyre h estimate (same order, not identical flow).
        -- Air->rim stays on its existing independently calibrated conductance.
        coreCavityNaturalConductanceWPerK = 2.8,
        coreCavityTurbulenceConductancePerSqrtMS = 0.95,
        innerLinerExternalHMatchFraction = 1.00,

        sidewallRollingLossReferenceShare = 0.38,
        sidewallReferenceAspect = 0.50,
        sidewallAspectLossExponent = 0.30,
        sidewallRollingLossMinShare = 0.30,
        sidewallRollingLossMaxShare = 0.35,
        rollingCoreMinimumShare = 0.05,

        coreSidewallBaseConductanceWPerK = 3.0,
        coreSidewallAreaExponent = 0.50,

        sidewallEquivalentThicknessM = 0.0060,
        sidewallMinTotalCapacityJPerK = 1400.0,
        sidewallMaxTotalCapacityJPerK = 9000.0,
        sidewallMaxFractionOfOldCoreCapacity = 0.80,
        sidewallGasAreaEffectiveness = 0.28,
        sidewallExternalAreaEffectiveness = 0.70,
        sidewallFlexBiasExponentGain = 1.25,
        sidewallMinPerSideHeatShare = 0.03,

        treadShoulderCoolingMaxWidthFactor = 1.30,

        rimReferenceMassKg = 9.0,
        rimReferenceRadiusM = 0.23,
        rimReferenceWidthM = 0.225,
        rimMassRadiusExponent = 1.45,
        rimMassWidthExponent = 0.45,
        rimMinMassKg = 3.5,
        rimMaxMassKg = 30.0,
        rimEffectiveCpJkgK = 720.0,
        rimMinimumCapacityJPerK = 2500.0,
        rimAreaScale = 0.88,

        rimStaticH_Wm2K = 8.0,
        rimForcedHPerSqrtMS_Wm2K = 7.0,
        rimRotationHPerSqrtMS_Wm2K = 2.0,
        wheelhouseAirspeedFraction = 0.72,

        brakeToRimConductanceWPerK = 1.05,
        carcassBeadToRimConductanceWPerK = 1.35,
        maxRimTemp = 220.0,
    },

    -- PREHEAT now creates an "operating-start" radial gradient instead of filling
    -- every reservoir to the compound working temperature. Fractions are measured
    -- from ambient toward the selected working temperature.
    preheatSurfaceFraction = 0.85,
    preheatRoadCellFraction = 0.80,
    preheatDeepTreadFraction = 0.55,
    preheatCoreFraction = 0.40,
    preheatAirFraction = 0.00,
    preheatHotCavityFraction = 0.50,
    preheatHotRimFractionOfGasDelta = 1.00,

    flashHeatTau = 0.022,
    flashCoolTau = 0.010,
    flashInputFraction = 0.10,
    flashInputSaturationW = 40000.0,
    flashToSurfaceConductance = 4.0,
    flashEffectiveRoadConductance = 16.0,
    flashMaxRetainedTyreShare = 0.20,

    -- Road-contact thermal boundary ownership (footprint geometry upgraded ).
    -- [GC-R1][LITERATURE-DERIVED] Direct tyre/track models use road-contact h values
    -- on the order of ~1.2 kW/m^2/K in conservative reduced-order race-tyre models;
    -- substantially larger instantaneous values are reported by detailed contact
    -- studies. Source: https://doi.org/10.1080/00423114.2024.2342534
    -- [GC-E1][KTS RESEARCH-GUIDED DEFAULT] KTS raw hGround is ~2.4 kW/m^2/K at
    -- 60 km/h, so 0.50 gives ~1.2 kW/m^2/K while preserving the existing load,
    -- mechanically-resolved contact-patch and speed dependence. deliberately removes
    -- any implication that PSI is an independent cooling scaler; see [CP-R1..R3]. The selected scale
    -- keeps bulk-tread dry-road cooling within the intended calibration range.
    -- Intrinsic rubber k/rho/cp and groove geometry are NOT modified here.
    thinSurfaceAirConductanceScale = 0.05,
    thinSurfaceRoadConductanceScale = 0.50,
    -- Ownership rule: there is intentionally NO second hotspot-only road-conductance
    -- coefficient here. The base tyre<->road boundary is routed into the signed
    -- circumferential feature (+J/-J), so a separate local dT-to-bulk correction
    -- would duplicate road-energy accounting.
    -- [RC-E2][KTS OWNERSHIP RULE] Road exchange has ONE owner only:
    -- thinSurfaceRoadConductanceScale -> actual local/bulk boundary routing.
    -- Do NOT re-add localizedHotspotRoadConductanceScale unless the boundary model
    -- is redesigned and the Joule ownership is proven non-overlapping.
    bulkTreadAirConductanceScale = 0.25,

    deformationSurfaceShare = 0.06,
    deformationTreadShare = 0.44,
    deformationCoreShare = 0.50,
    rollingSurfaceShare = 0.02,
    rollingTreadShare = 0.12,
    rollingCoreShare = 0.86,
    maxSlipSpeed = 80.0,
    degradationStart = 155.0,
    degradationWPerK2 = 8.0,
    lateralSlipGCoeff = 0.055,

    roadPatchHeatCapacityPerM2 = 30000.0,
    roadPatchMinCapacity = 500.0,
    roadPatchStaticRecoveryTau = 45.0,
    roadRefreshLengthFactor = 1.0,
}

-- Reduced-order 1-D tread solver. Research ref: [R13]. Each OUTER/MIDDLE/INNER band owns a 12-cell
-- through-depth temperature field. The grid follows Fourier diffusion rather than
-- four hand-tuned lumped reservoirs. Flash remains a separate microscopic state and
-- the carcass/air remains one slow lumped boundary below the tread.
--
-- Research basis: transient conduction uses rho*c*dT/dt = k*d2T/dx2 + qVol and
-- slip-loss power is tangential stress dot LOCAL micro-sliding velocity. Because
-- Vehicle Lua does not expose the contact-patch velocity field, microSlipFactor below
-- is a bounded reduced-order approximation: near brush saturation most macro slip is
-- still tread deflection; with large excess slip it asymptotically approaches the
-- full wheel/road relative speed.

-- Immutable direct-value preset snapshots used by the Advanced reset buttons.
-- Copy once before any manual tuning mutates the live profiles.
M._physicalThermal.profilePresetDefaults = {}
M._physicalThermal.captureProfilePresetDefaults = function()
    for profileKey, liveProfile in pairs(M._physicalThermal.profiles) do
        local presetCopy = {}
        for field, value in pairs(liveProfile) do presetCopy[field] = value end
        M._physicalThermal.profilePresetDefaults[profileKey] = presetCopy
    end
end
M._physicalThermal.captureProfilePresetDefaults()

M._physicalThermal.resetProfileToPreset = function(profileKey)
    local preset = M._physicalThermal.profilePresetDefaults[tostring(profileKey or "")]
    local live = M._physicalThermal.profiles[tostring(profileKey or "")]
    if type(preset) ~= "table" or type(live) ~= "table" then return false end
    for field in pairs(live) do live[field] = nil end
    for field, value in pairs(preset) do live[field] = value end
    return true
end

M._physicalThermal.resetAllProfilesToPreset = function()
    for profileKey in pairs(M._physicalThermal.profiles) do
        M._physicalThermal.resetProfileToPreset(profileKey)
    end
    return true
end

M._physicalThermal.getProfileClassKey = function(profile)
    if type(profile) ~= "table" then return "standard" end
    local classId = tostring(profile.classId or "")
    if classId ~= "" and M._physicalThermal.profiles[classId] then return classId end
    local id = tostring(profile.id or "standard")
    if M._physicalThermal.profiles[id] then return id end
    return "standard"
end

M._physicalThermal.getPhysicalProfile = function(profile)
    local key = M._physicalThermal.getProfileClassKey(profile)
    return M._physicalThermal.profiles[key] or M._physicalThermal.profiles.standard, key
end

M._physicalThermal.getEffectiveTreadMaterial = function(profile)
    local physical, key = M._physicalThermal.getPhysicalProfile(profile)
    local function matnum(value, fallback)
        local n = tonumber(value)
        if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback end
        return n
    end
    return {
        classKey = key,
        conductivity = math.max(matnum(physical.rubberConductivity, M._physicalThermal.rubberConductivity), 0.02),
        density = math.max(matnum(physical.rubberDensity, M._physicalThermal.rubberDensity), 100),
        cp = math.max(matnum(physical.rubberCp, M._physicalThermal.rubberCp), 100),
        provenance = physical.materialProvenance or "profile-direct",
        confidence = physical.materialConfidence or "preset",
        source = "profile-direct"
    }
end

M._tread1D = {
    enabled = true,
    cells = 12,
    thermalMasterHz = 60,
    thermalMaxCatchupTicks = 12,
    cellRateDivisors = {1,2,2,4,4,4,8,8,8,8,12,12},
    adaptiveCellRetirementEnabled = true,
    adaptiveStartDepthRatio = 0.50,
    adaptiveRetirementEpsilonM = 1e-8,
    -- direct compound grip is PHYSICAL-DEPTH owned, not cell-count owned.
    -- Every tread cell participates through the exact integral of exp(-x/lambda) over
    -- its physical depth interval, so Standard/Sport/Semi/Slick/Rally/Drift all use the
    -- same road-side friction depth even when total tread thickness or wear changes.
    --
    -- [GRIP-R1][LITERATURE] Multi-layer racing-tyre thermal model: a ~0.5 mm fast
    -- surface layer is required to represent contact-patch response/frictional
    -- penetration; fitted thickness is slightly >0.5 mm and >80% of sliding-friction
    -- POWER enters this layer. This is a thermal-power anchor, NOT a claim that the
    -- first 0.5 mm owns 80% of friction force.
    -- https://link.springer.com/chapter/10.1007/978-3-031-66968-2_29
    -- [GRIP-R2][LITERATURE] Tyre/road rubber penetration is reported around 0.5-0.6 mm
    -- above ~60 km/h and ~1 mm at zero speed in published texture/contact work.
    -- https://www.researchgate.net/publication/279212135_Quantifying_aggregate_microtexture_with_respect_to_wear-Case_of_New_Zealand_aggregates
    -- [GRIP-R3][LITERATURE] Road microtexture below ~0.5 mm is a major tyre-friction
    -- input; rubber friction depends strongly on tread viscoelasticity/temperature.
    -- https://www.sciencedirect.com/science/article/pii/S0022489820300975
    -- [GRIP-E1][KTS RESEARCH-GUIDED KERNEL] lambda=0.65 mm is a reduced-order
    -- compromise between the ~0.5-0.6 mm fast/contact penetration scale and the
    -- deeper macrotexture/subsurface deformation field. It is NOT a universal measured
    -- tyre constant. Integrated authority is ~53.7% in 0-0.5 mm, ~36.4% in
    -- 0.5-1.5 mm and ~9.9% below 1.5 mm for a thick tread.
    gripDepthDecayM = 0.00065,
    minimumSimDepthM = 0.00050,
    nonWearableReserveM = 0.00050,
    extraFlexHysteresisFraction = 0.08,
    longitudinalDeformationTreadShare = 0.45,
    longitudinalDeformationSidewallShare = 0.45,
    lateralDeformationTreadShare = 0.45,
    lateralDeformationSidewallShare = 0.50,

    rollingTyreRetainedFraction = 0.90,

    treadRollingHeatShare = 0.60,
    rollingShoulderZoneBias = 1.25,
    rollingCentreZoneBias = 0.70,

    --
    --
    --
    wearDepthHeatCoupling = {
        enabled = true,
        depthExponent = 1.00,

        rollingTreadDependentFraction = 0.25,

        longitudinalTreadDependentFraction = 0.58,
        lateralTreadDependentFraction = 0.65,
    },

    maxCellTemp = 340.0,
    uncappedRoadSideCells = 3,
    virtualWearZoneBiasMin = 0.25,
    virtualWearZoneBiasMax = 2.50,
    surfaceBoundaryRiseTauS = 0.025,
    surfaceBoundaryFallTauS = 0.080,
}

M._tread1D._finiteNumber = function(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end
M._tread1D._clamp = function(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

M._tread1D.getGripDepthBoundsWeight = function(x0M, x1M, decayM)
    local finite = M._tread1D._finiteNumber
    local decay = math.max(finite(decayM, M._tread1D.gripDepthDecayM), 1e-6)
    local x0 = math.max(finite(x0M, 0), 0)
    local x1 = math.max(finite(x1M, x0), x0)
    return math.max(math.exp(-x0 / decay) - math.exp(-x1 / decay), 0)
end

M._tread1D.getGripDepthCellWeight = function(cellIndex, cellCount, simDepthM, decayM)
    local finite = M._tread1D._finiteNumber
    local bound = M._tread1D._clamp
    local n = math.max(math.floor(finite(cellCount, M._tread1D.cells)), 1)
    local j = bound(math.floor(finite(cellIndex, 1)), 1, n)
    local depth = math.max(finite(simDepthM, M._tread1D.minimumSimDepthM), 1e-6)
    local dx = depth / n
    return M._tread1D.getGripDepthBoundsWeight((j - 1) * dx, j * dx, decayM)
end

M._tread1D.getDepthIntervalAverage = function(field, simDepthM, startFrac, endFrac, fallback)
    local finite = M._tread1D._finiteNumber
    local bound = M._tread1D._clamp
    local n = type(field) == "table" and #field or 0
    if n < 1 then return finite(fallback, ENV_TEMP) end
    local depth = math.max(finite(simDepthM, M._tread1D.minimumSimDepthM), 1e-6)
    local a = bound(finite(startFrac, 0), 0, 1) * depth
    local b = bound(finite(endFrac, 1), 0, 1) * depth
    if b < a then a, b = b, a end
    if b - a < 1e-9 then return finite(fallback, ENV_TEMP) end
    local dx = depth / n
    local sum, span = 0, 0
    for j = 1, n do
        local x0 = (j - 1) * dx
        local x1 = j * dx
        local overlap = math.max(math.min(x1, b) - math.max(x0, a), 0)
        if overlap > 0 then
            sum = sum + finite(field[j], fallback) * overlap
            span = span + overlap
        end
    end
    return span > 0 and sum / span or finite(fallback, ENV_TEMP)
end

-- Research-based wear model. Research ref: [R11]. Abrasion is evaluated in the local
-- sliding zone using the measured tread-rubber wear relationship reported by
-- Liu & Cebon (Cambridge, 2025):
-- w / w0 = k1 * (p / p0) * (1 + k2 * v / v0)
-- where w is mass loss per unit area per unit sliding distance. Their field-validated
-- road fits gave k1 of roughly 0.136-0.276 and laboratory fits gave k2 ~= 0.37.
-- v13.10.5 recalibrates the road coefficient and pre-saturation micro-slip after
-- Macau testing showed normal clean laps still consuming far too much tread. The
-- research law shape is retained, but ordinary asphalt uses k1=0.040 and the local
-- sliding estimate is much smaller while U<1. Once the brush exceeds saturation,
-- the existing exponential branch still ramps rapidly toward full relative slip so
-- burnouts, lockups and real power-slides remain destructive. Temperature stays ~flat
-- through the normal working window; only genuine overheat raises abrasion strongly.
M._wearResearch = {
    enabled = true,
    baseRoadK1 = 0.040,
    velocitySlopeK2 = 0.37,
    referencePressurePa = 1000000.0,
    referenceSlidingSpeedMps = 1.0,
    preSaturationLocalSlipMin = 0.008,
    preSaturationLocalSlipAtU1 = 0.14,
    preSaturationExponent = 2.15,
    excessSlipGain = 3.20,
    contactDutyMax = 0.20,

    regenVisualTestMultiplier = 1.0,
    waterWearMultiplier = 0.35,
    grassWearMultiplier = 0.12,

    -- actual-friction-work authority.  The Liu/Cebon bi-linear law above
    -- was calibrated on one abrasive surface family, so pressure + sliding distance
    -- alone cannot know whether BeamNG is currently giving the tyre asphalt-level
    -- shear force or almost no force on ice/very-low-mu ground.  Research ref [R16]
    -- supports frictional work density as tau_x*v_x + tau_y*v_y: side-force work is
    -- therefore not a special extra wear channel; it enters through the SAME actual
    -- tangential work scalar as longitudinal wheelspin/braking.
    --
    -- We normalize BeamNG wheelRotator.slipEnergy against what the SAME wheel/load/
    -- slip state would dissipate on Beam's live dry ASPHALT model.  This deliberately
    -- preserves the already-calibrated dry-asphalt wear level while allowing low-mu
    -- surfaces to wear less and high-mu/prepped surfaces to wear more.  SurfaceScale
    -- remains separate: it represents abrasiveness/material (grass/water/dirt), not
    -- available tangential force.
    frictionWork = {
        enabled = true,
        exponent = 1.0,                 -- literature-derived energetic first pass: wear ~ frictional work
        authorityMin = 0.0,
        authorityMax = 2.0,             -- KTS engineering safety cap for extreme/custom high-mu surfaces
        nativeBlendBStart = 0.08,       -- KTS engineering default: avoid noisy force ratios in tiny micro-slip
        nativeBlendBFull = 0.35,
        minReferencePowerW = 1.0,
        fallbackAsphaltStaticMu = 1.0,
        fallbackAsphaltSlidingMu = 0.70,
        fallbackAsphaltStribeckVelocityMps = 6.0,
    },
    profileK1Scale = {
        standard = 0.85,
        sport = 1.00,
        -- [TG-R14][KTS RESEARCH-GUIDED ENGINEERING CALIBRATION]: Semi / Sport Plus 2R
        -- gets its own high-shear abrasion material class instead of inheriting Sport solely because
        -- its shared mechanical backend uses profile.id="sport". 0.65 is an engineering calibration,
        -- NOT a direct UTQG conversion; Cup 2 R (UTQG 140) versus dedicated race references such as
        -- Hoosier R7 (UTQG 40) supports a road-legal extreme-track tyre being materially more durable
        -- than soft/sprint race rubber while still less road-life-oriented than PS4/PS4S families.
        semi_slick = 0.65,
        race = 0.50,
        rally_asphalt = 0.80,
        rally_gravel = 1.35,
        drift = 0.70,
    },

}

M._wearResearch.finiteNumber = function(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

M._wearResearch.clamp = function(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

M._wearResearch.getProfileScale = function(profile)
    local cfg = M._wearResearch
    local classId = profile and profile.classId or nil
    local id = profile and profile.id or "standard"
    local scale = classId and cfg.profileK1Scale[classId] or nil
    if scale == nil then scale = cfg.profileK1Scale[id] end
    return cfg.clamp(cfg.finiteNumber(scale, 1.0), 0.25, 3.0)
end

M._wearResearch.getUnifiedLocalRubbingFactor = function(brushU)
    local cfg = M._wearResearch
    local u = math.max(cfg.finiteNumber(brushU, 0), 0)
    return u > 0 and 1.0 or 0.0
end

M._wearResearch.getLocalSlipFactor = function(brushU)
    return M._wearResearch.getUnifiedLocalRubbingFactor(brushU)
end

M._wearResearch.getAbrasionSlidingScale = function(profile, brushU)
    local cfg = M._wearResearch
    local u = math.max(cfg.finiteNumber(brushU, 0), 0)
    return u > 0 and 1.0 or 0.0
end

-- actual tangential friction-work observer for abrasion.
-- DIRECT BEAMNG SIGNAL: wheels.wheelRotators[wheelID].slipEnergy, already used by
-- the KTS sliding-heat path. Historical BeamNG wheel code defines it from
-- slipForce * slipVelocity (E/dt), so it naturally contains BOTH Fx*Vx and Fy*Vy.
--
-- Why normalize to dry asphalt instead of multiplying Cambridge wear by raw power?
-- The existing k1/profile scales were already calibrated on Beam dry-asphalt driving.
-- A raw-power multiplier would silently make high-grip tyre families wear 2x merely
-- because their native noLoadCoef is larger. The reference below reconstructs the
-- same wheel's expected dry-asphalt sliding work (including its tyre friction fields,
-- approximate per-node load sensitivity, current KTS grip scale and Stribeck state).
-- Therefore dry asphalt stays ~1.0, while the *measured departure* in actual friction
-- work becomes the new surface/force authority.
M._wearResearch.getFrictionWorkWearState = function(wheelID, geom, slidingFraction)
    local cfg=M._wearResearch
    local fc=type(cfg.frictionWork)=="table" and cfg.frictionWork or {}
    local B=cfg.clamp(cfg.finiteNumber(slidingFraction,0),0,1)
    local slipSpeed=math.max(cfg.finiteNumber(geom and geom.safeSlipSpeed,0),0)
    local loadN=math.max(cfg.finiteNumber(geom and geom.safeLoad,0),0)
    local native=geom and geom.nativeSlipPower or nil
    local state={
        authority=1.0, rawAuthority=1.0, confidence=0.0, source="legacy-unity-fallback",
        actualPowerW=0, referenceDryPowerW=0, actualEquivalentForceN=0,
        equivalentFxN=0, equivalentFyN=0, actualSlidingPatchMu=0,
        referenceDryPatchMu=0, longitudinalWorkShare=0, lateralWorkShare=0,
        loadedNodeCoef=1.0, loadedNodeCount=0,
    }
    if fc.enabled==false or B<=0 or slipSpeed<=1e-6 or loadN<=1e-6 or type(native)~="table" then
        return state
    end

    local actualPowerW=math.max(cfg.finiteNumber(native.powerW,0),0)
    local wr=wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    if actualPowerW<0 or type(wr)~="table" then return state end

    local tyreStatic=math.max(cfg.finiteNumber(wr.frictionCoef,1.0),0.001)
    local tyreSliding=math.max(cfg.finiteNumber(wr.slidingFrictionCoef,tyreStatic),0.001)
    local noLoad=math.max(cfg.finiteNumber(wr.noLoadCoef,1.0),0.001)
    local fullLoad=math.max(cfg.finiteNumber(wr.fullLoadCoef,1.0),0.001)
    local slope=math.max(cfg.finiteNumber(wr.loadSensitivitySlope,0),0)
    local lowerCoef,upperCoef=math.min(noLoad,fullLoad),math.max(noLoad,fullLoad)

    -- Reduced-order loaded-node reconstruction used by the abrasion power model:
    -- estimate how many paired tread nodes geometrically span the footprint, then
    -- apply Beam's documented linear per-node load-sensitivity law.  This is used
    -- ONLY to build the dry-asphalt normalization; actual wear authority still comes
    -- from BeamNG's measured slipEnergy.
    local numRays=math.max(math.floor(cfg.finiteNumber(wr.numRays,16)+0.5),4)
    local treadNodeCount=numRays*2
    local radius=math.max(cfg.finiteNumber(geom and geom.safeRadius,0.33),0.01)
    local patchLength=math.max(cfg.finiteNumber(geom and geom.footprintLength,0),0)
    local chordRatio=cfg.clamp(patchLength/math.max(2*radius,1e-6),0,0.999999)
    local footprintAngle=2*math.asin(chordRatio)
    local loadedNodes=cfg.clamp(math.max(treadNodeCount*footprintAngle/(2*math.pi),2),2,treadNodeCount)
    local loadPerNode=loadN/math.max(loadedNodes,1)
    local loadCoef=slope>0 and cfg.clamp(noLoad-loadPerNode*slope,lowerCoef,upperCoef) or 1.0

    local asphalt=groundModels and (groundModels.ASPHALT or groundModels.asphalt) or nil
    asphalt=type(asphalt)=="table" and asphalt or {}
    local groundStatic=math.max(cfg.finiteNumber(asphalt.staticFrictionCoefficient,
        cfg.finiteNumber(fc.fallbackAsphaltStaticMu,1.0)),0.001)
    local groundSliding=math.max(cfg.finiteNumber(asphalt.slidingFrictionCoefficient,
        cfg.finiteNumber(fc.fallbackAsphaltSlidingMu,0.70)),0.001)
    local exponent=cfg.clamp(cfg.finiteNumber(wr.stribeckExponent,1.75),0.10,8.0)
    local velMult=cfg.clamp(cfg.finiteNumber(wr.stribeckVelMult,1.0),0.05,10.0)
    local groundVs=math.max(cfg.finiteNumber(asphalt.stribeckVelocity,
        cfg.finiteNumber(fc.fallbackAsphaltStribeckVelocityMps,6.0)),0.05)
    local effectiveVs=math.max(groundVs*velMult,0.05)
    local staticMu=groundStatic*tyreStatic
    local slidingMu=groundSliding*tyreSliding
    local ultimateRatio=cfg.clamp(slidingMu/math.max(staticMu,0.001),0.05,2.0)
    local staticWeight=math.exp(-((slipSpeed/effectiveVs)^exponent))
    local nodeRatio=ultimateRatio+(1-ultimateRatio)*staticWeight
    local gripScale=cfg.clamp(cfg.finiteNumber(tyreGripTable and tyreGripTable[wheelID],1.0),0.05,2.0)
    local referenceDryPatchMu=staticMu*nodeRatio*loadCoef*gripScale
    local referenceDryForceN=referenceDryPatchMu*loadN*B
    local referenceDryPowerW=referenceDryForceN*slipSpeed

    local rawAuthority=1.0
    if referenceDryPowerW>math.max(cfg.finiteNumber(fc.minReferencePowerW,1.0),1e-6) then
        rawAuthority=actualPowerW/referenceDryPowerW
    end
    rawAuthority=cfg.clamp(rawAuthority,
        cfg.finiteNumber(fc.authorityMin,0.0),cfg.finiteNumber(fc.authorityMax,2.0))
    rawAuthority=rawAuthority^math.max(cfg.finiteNumber(fc.exponent,1.0),0.01)

    -- Near-zero B is dominated by reconstruction noise and the Cambridge law already
    -- makes wear tiny. Blend from the legacy calibrated value to measured-force
    -- authority, then become fully physical before gross sliding/drifting/lockup.
    local b0=cfg.clamp(cfg.finiteNumber(fc.nativeBlendBStart,0.08),0,1)
    local b1=math.max(cfg.clamp(cfg.finiteNumber(fc.nativeBlendBFull,0.35),0,1),b0+1e-6)
    local x=cfg.clamp((B-b0)/(b1-b0),0,1)
    local confidence=x*x*(3-2*x)
    local authority=1+(rawAuthority-1)*confidence

    local eqFt=math.max(cfg.finiteNumber(native.equivalentTangentialForceN,
        actualPowerW/math.max(slipSpeed,1e-6)),0)
    local eqFx=math.max(cfg.finiteNumber(native.equivalentFxN,0),0)
    local eqFy=math.max(cfg.finiteNumber(native.equivalentFyN,0),0)
    local longPower=math.max(cfg.finiteNumber(native.longitudinalPowerW,0),0)
    local latPower=math.max(cfg.finiteNumber(native.lateralPowerW,0),0)
    local powerSum=math.max(longPower+latPower,actualPowerW,1e-9)

    state.authority=authority; state.rawAuthority=rawAuthority; state.confidence=confidence
    state.source="beamng-slipEnergy-vs-same-wheel-dry-asphalt-reference"
    state.actualPowerW=actualPowerW; state.referenceDryPowerW=referenceDryPowerW
    state.actualEquivalentForceN=eqFt; state.equivalentFxN=eqFx; state.equivalentFyN=eqFy
    state.actualSlidingPatchMu=eqFt/math.max(loadN*B,1e-9)
    state.referenceDryPatchMu=referenceDryPatchMu
    state.longitudinalWorkShare=longPower/powerSum; state.lateralWorkShare=latPower/powerSum
    state.loadedNodeCoef=loadCoef; state.loadedNodeCount=loadedNodes
    return state
end

--
--
M._wearResearch.wearThermalUStart = 0.55
M._wearResearch.wearThermalUFull = 1.35

-- microscopic flash-temperature DESTRUCTIVE-SKIN coupling.
--
-- SCALE OWNERSHIP (important):
-- * The Cambridge/Liu-Cebon bi-linear law remains the sole owner of the nominal
-- abrasion shape from pressure, sliding speed, sliding-load fraction B, material
-- family and contact duty. then applies ONE measured friction-work
-- authority relative to the same wheel on dry asphalt; this is a surface/shear
-- correction, not a second wear-mass model.
-- * The existing macro thermal observer (surface + cell1 + cell2) still modifies
-- that rate for bulk/material softening exactly as before .
-- * The EXISTING data.flash_temp state is a microscopic asperity temperature. It
-- therefore does NOT multiply the entire nominal contact patch. Instead only a
-- small hot micro-contact population can add a bounded equivalent wear term.
--
-- Research / provenance:
-- DIRECTLY SOURCED PHYSICS: Persson, "Rubber friction: role of the flash
-- temperature". Flash heating is localized at roughness contacts and evolves on
-- microscopic/short time scales; it is not a finite-thickness bulk tread state.
-- https://pubmed.ncbi.nlm.nih.gov/21690888/
-- DIRECTLY SOURCED FAILURE MODE: FAA AC 65-15A describes locked-wheel/brakes-on
-- skid heating severe enough to melt/scuff tread rubber ("skid burn").
-- https://www.faa.gov/documentlibrary/media/advisory_circular/ac_65-15a.pdf
-- LITERATURE-DERIVED MATERIAL BOUNDS: tyre/rubber thermal-degradation studies put
-- minor volatile/additive loss broadly in the ~200-350 C region and major network
-- decomposition mostly above ~350 C. These are NOT tyre-family melting points.
-- https://4spepublications.onlinelibrary.wiley.com/doi/10.1002/pc.70314
-- PRODUCT-SPEC-DERIVED ORDERING: Pirelli rally/F1 compound descriptions support
-- softer compounds being lower-temperature/lower-durability and harder compounds
-- tolerating hotter, more energetic duty.
-- https://www.pirelli.com/tyres/en-au/motorsport/car/formula-1
-- https://www.pirelli.com/tyres/en-au/motorsport/car/rally/catalog/p-zero-ra
-- https://www.pirelli.com/tires/en-us/motorsport/car/rally/catalog/scorpion-at
--
-- Exact knees remain KTS ENGINEERING DEFAULTS constrained by those sources. They
-- describe the microscopic destructive-skin regime, NOT the average temperature of
-- cell1 or the full tread block.
M._wearResearch.flashDestructiveWearProfiles = {
    standard = {damageKneeC = 180, ablationKneeC = 245},
    sport = {damageKneeC = 195, ablationKneeC = 255},
    semi_slick = {damageKneeC = 210, ablationKneeC = 275},
    race = {
        supersoft = {damageKneeC = 180, ablationKneeC = 235},
        soft      = {damageKneeC = 200, ablationKneeC = 255},
        medium    = {damageKneeC = 220, ablationKneeC = 280},
        hard      = {damageKneeC = 240, ablationKneeC = 300},
    },
    rally_asphalt = {
        supersoft = {damageKneeC = 170, ablationKneeC = 215},
        soft      = {damageKneeC = 188, ablationKneeC = 235},
        medium    = {damageKneeC = 210, ablationKneeC = 260},
        hard      = {damageKneeC = 235, ablationKneeC = 295},
    },
    rally_gravel = {
        supersoft = {damageKneeC = 180, ablationKneeC = 225},
        soft      = {damageKneeC = 205, ablationKneeC = 250},
        medium    = {damageKneeC = 228, ablationKneeC = 280},
        hard      = {damageKneeC = 242, ablationKneeC = 300},
    },
}

--
M._wearResearch.flashMicroHotAreaFraction = 0.0

M._wearResearch.flashDestructiveInternalMaxFactor = 20.0

-- [KTS ENGINEERING DEFAULT, literature-scale] 10 micrometres ~= 0.01 mm. This is of
-- the same order as sqrt(alpha*t) for rubber over ~1 ms flash events (alpha~1e-7 m2/s).
-- Ordinary wear retains the >=0.1%-of-usable-depth write deadband. Only wear generated
-- while the microscopic flash is already beyond the ABLAtion knee may bypass it, and
-- only after >=10 um has accumulated in any zone. This rare 60 Hz path exists so the
-- sacrificial hot skin can actually expose cooler rubber instead of waiting 200 ms.
M._wearResearch.flashFastRemeshThresholdM = 0.000010

-- DESTRUCTIVE-SLIDING ENERGY OWNERSHIP.
--
-- Cambridge/Liu-Cebon remains the ONLY owner of removed rubber mass. This block does
-- NOT create extra wear. Instead, the already-predicted removed mass owns an energy
-- sink before retained friction heat is deposited into surviving tread rubber:
-- Q_destroy = m_removed * activation(T_flash) * H_destroy
--
-- [DE-R1][MEASURED / MODEL-FITTED] SBR pyrolysis experiments identified an effective
-- pyrolysis enthalpy of ~200 kJ/kg. Use that as the conservative first-pass bond-
-- breaking/decomposition sink rather than summing every reported reaction/vaporisation
-- term and accidentally double-counting sensible heat already exported by remeshing.
-- https://www.sciencedirect.com/science/article/pii/S0165237008000661
-- [DE-R2][MEASURED] Tyre-rubber DTA work resolves reaction and ~170-200 kJ/kg
-- vaporisation terms and shows that the total thermal budget is chemistry-dependent.
-- This supports keeping the first implementation conservative and separately traceable.
-- https://www.sciencedirect.com/science/article/pii/S0040603196030171
-- [DE-R3][LITERATURE] Low-temperature tyre-rubber work shows strong molecular-weight
-- degradation by ~267-282 C and near-removal of rubber matrix above ~320 C, supporting
-- progressive activation through the existing compound damage/ablation knees rather
-- than an artificial finite-cell temperature clamp.
-- https://pmc.ncbi.nlm.nih.gov/articles/PMC11886908/
--
-- The existing remesh still separately exports the SENSIBLE enthalpy already stored in
-- hot removed rubber. Q_destroy is therefore chemistry/tearing/ejecta work; remesh export
-- is hot-mass sensible energy. Keep both paths distinct.
M._wearResearch.destructionEnergy = {
    enabled = true,
    enthalpyJPerKg = 200000.0,
    maxGrossRetainedFraction = 1.0,
    activation = "smoothstep-damage-to-ablation",
    provenance = "DE-R1 measured/model-fitted SBR 200 kJ/kg; DE-R2/R3 bounds; KTS conservative first-pass",
}

M._wearResearch.thermalWearProfiles = {
    standard = {
        weights = {surface = 0.05, cell1 = 0.50, cell2 = 0.45},
        highWeights = {surface = 0.25, cell1 = 0.55, cell2 = 0.20},
        hotStartOffsetC = 5,
        hotPoints = {{0,1.00},{20,1.08},{50,1.30},{90,1.70},{140,2.20}},
    },
    sport = {
        weights = {surface = 0.08, cell1 = 0.52, cell2 = 0.40},
        highWeights = {surface = 0.28, cell1 = 0.57, cell2 = 0.15},
        hotStartOffsetC = 5,
        hotPoints = {{0,1.00},{20,1.10},{50,1.35},{90,1.85},{140,2.50}},
    },
    drift = {
        weights = {surface = 0.08, cell1 = 0.52, cell2 = 0.40},
        highWeights = {surface = 0.30, cell1 = 0.58, cell2 = 0.12},
        hotStartOffsetC = 20,
        hotPoints = {{0,1.00},{30,1.05},{70,1.20},{120,1.50},{180,1.80}},
    },
    race = {
        supersoft = {
            weights = {surface = 0.14, cell1 = 0.60, cell2 = 0.26},
            highWeights = {surface = 0.37, cell1 = 0.54, cell2 = 0.09},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{12,1.14},{30,1.52},{52,2.35},{80,3.55},{115,4.80}},
        },
        soft = {
            weights = {surface = 0.12, cell1 = 0.58, cell2 = 0.30},
            highWeights = {surface = 0.34, cell1 = 0.56, cell2 = 0.10},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{15,1.12},{35,1.42},{60,2.10},{90,3.20},{130,4.40}},
        },
        medium = {
            weights = {surface = 0.10, cell1 = 0.55, cell2 = 0.35},
            highWeights = {surface = 0.30, cell1 = 0.60, cell2 = 0.10},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{20,1.10},{45,1.35},{75,2.80},{110,3.80},{150,4.80}},
        },
        hard = {
            weights = {surface = 0.08, cell1 = 0.52, cell2 = 0.40},
            highWeights = {surface = 0.27, cell1 = 0.60, cell2 = 0.13},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{25,1.08},{55,1.28},{90,2.40},{130,3.20},{170,4.00}},
        },
    },
    rally_asphalt = {
        supersoft = {
            weights = {surface = 0.13, cell1 = 0.57, cell2 = 0.30},
            highWeights = {surface = 0.36, cell1 = 0.54, cell2 = 0.10},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{12,1.16},{28,1.55},{50,2.35},{78,3.45},{115,4.50}},
        },
        soft = {
            weights = {surface = 0.11, cell1 = 0.56, cell2 = 0.33},
            highWeights = {surface = 0.33, cell1 = 0.56, cell2 = 0.11},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{16,1.13},{36,1.45},{62,2.15},{95,3.10},{135,4.10}},
        },
        medium = {
            weights = {surface = 0.09, cell1 = 0.54, cell2 = 0.37},
            highWeights = {surface = 0.30, cell1 = 0.58, cell2 = 0.12},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{20,1.10},{45,1.36},{75,1.95},{110,2.75},{155,3.65}},
        },
        hard = {
            weights = {surface = 0.07, cell1 = 0.51, cell2 = 0.42},
            highWeights = {surface = 0.27, cell1 = 0.59, cell2 = 0.14},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{25,1.08},{55,1.28},{90,1.78},{130,2.45},{180,3.20}},
        },
    },
    rally_gravel = {
        supersoft = {
            weights = {surface = 0.09, cell1 = 0.51, cell2 = 0.40},
            highWeights = {surface = 0.28, cell1 = 0.57, cell2 = 0.15},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{15,1.14},{35,1.48},{62,2.15},{95,3.05},{140,4.00}},
        },
        soft = {
            weights = {surface = 0.08, cell1 = 0.50, cell2 = 0.42},
            highWeights = {surface = 0.26, cell1 = 0.58, cell2 = 0.16},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{20,1.12},{45,1.40},{75,1.95},{110,2.70},{155,3.50}},
        },
        medium = {
            weights = {surface = 0.07, cell1 = 0.48, cell2 = 0.45},
            highWeights = {surface = 0.24, cell1 = 0.58, cell2 = 0.18},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{25,1.10},{55,1.34},{90,1.82},{130,2.42},{180,3.10}},
        },
        hard = {
            weights = {surface = 0.06, cell1 = 0.46, cell2 = 0.48},
            highWeights = {surface = 0.22, cell1 = 0.58, cell2 = 0.20},
            hotStartOffsetC = 0,
            hotPoints = {{0,1.00},{30,1.08},{65,1.28},{105,1.68},{150,2.18},{205,2.75}},
        },
    },
}

M._wearResearch.getThermalWearCalibration = function(profile)
    local cfg = M._wearResearch
    local set = cfg.thermalWearProfiles or {}
    local id = profile and profile.id or "standard"
    if id == "race" then
        local race = set.race or {}
        local compoundId = (M._slickCompounds and M._slickCompounds.getPreset
            and M._slickCompounds.getPreset()) or "medium"
        return race[compoundId] or race.medium or set.sport or set.standard
    end
    if id == "rally_asphalt" or id == "rally_gravel" then
        local rally = set[id] or {}
        local compoundId = (M._rallyCompounds and M._rallyCompounds.getCompoundPreset
            and M._rallyCompounds.getCompoundPreset()) or "medium"
        return rally[compoundId] or rally.medium or set.sport or set.standard
    end
    return set[id] or set.standard
end

M._wearResearch.getFlashDestructiveWearCalibration = function(profile)
    local cfg = M._wearResearch
    local set = cfg.flashDestructiveWearProfiles or {}
    local id = profile and profile.id or "standard"
    if profile and profile.classId == "semi_slick" then return set.semi_slick end
    if id == "race" then
        local race = set.race or {}
        local compoundId = (M._slickCompounds and M._slickCompounds.getPreset
            and M._slickCompounds.getPreset()) or "medium"
        return race[compoundId] or race.medium
    end
    if id == "rally_asphalt" or id == "rally_gravel" then
        local rally = set[id] or {}
        local compoundId = (M._rallyCompounds and M._rallyCompounds.getCompoundPreset
            and M._rallyCompounds.getCompoundPreset()) or "medium"
        return rally[compoundId] or rally.medium
    end
    return set[id]
end

M._wearResearch.getFlashDestructiveInternalFactor = function(flashTempC, profile)
    local cfg = M._wearResearch
    local cal = cfg.getFlashDestructiveWearCalibration(profile)
    if type(cal) ~= "table" then return 1.0, nil, nil end
    local damage = cfg.finiteNumber(cal.damageKneeC, 220)
    local ablation = math.max(cfg.finiteNumber(cal.ablationKneeC, damage + 50), damage + 1)
    local t = cfg.finiteNumber(flashTempC, damage)
    if t <= damage then return 1.0, damage, ablation end
    if t <= ablation then
        local x = cfg.clamp((t - damage) / (ablation - damage), 0, 1)
        return 1.0 + x * x * x, damage, ablation
    end
    local over = t - ablation
    local factor
    if over <= 25 then
        factor = 2.0 + 3.0 * (over / 25)
    elseif over <= 50 then
        factor = 5.0 + 5.0 * ((over - 25) / 25)
    elseif over <= 100 then
        factor = 10.0 + 10.0 * ((over - 50) / 50)
    else
        factor = cfg.finiteNumber(cfg.flashDestructiveInternalMaxFactor, 20.0)
    end
    return cfg.clamp(factor, 1.0, cfg.finiteNumber(cfg.flashDestructiveInternalMaxFactor, 20.0)), damage, ablation
end

M._wearResearch.getEffectiveWearTemperature = function(data, zone, profile, brushU)
    local cfg = M._wearResearch
    local cal = cfg.getThermalWearCalibration(profile) or {}
    local low = cal.weights or {surface = 0.10, cell1 = 0.55, cell2 = 0.35}
    local high = cal.highWeights or low
    local surface = cfg.finiteNumber(
        data and data.circumferential_contact_surface_temp_zone_c
            and data.circumferential_contact_surface_temp_zone_c[zone],
        cfg.finiteNumber(data and data.surface_temp and data.surface_temp[zone],
            cfg.finiteNumber(data and data.temp and data.temp[zone], ENV_TEMP)))
    local field = data and data.tread_field and data.tread_field[zone] or nil
    local cell1 = cfg.finiteNumber(
        data and data.circumferential_contact_tread_cell1_temp_zone_c
            and data.circumferential_contact_tread_cell1_temp_zone_c[zone],
        cfg.finiteNumber(field and field[1],
            cfg.finiteNumber(data and data.temp and data.temp[zone], surface)))
    local cell2 = cfg.finiteNumber(
        data and data.circumferential_contact_tread_cell2_temp_zone_c
            and data.circumferential_contact_tread_cell2_temp_zone_c[zone],
        cfg.finiteNumber(field and field[2], cell1))

    local u0 = cfg.finiteNumber(cfg.wearThermalUStart, 0.55)
    local u1 = math.max(cfg.finiteNumber(cfg.wearThermalUFull, 1.35), u0 + 1e-6)
    local blend = cfg.clamp((math.max(cfg.finiteNumber(brushU, 0), 0) - u0) / (u1 - u0), 0, 1)
    blend = blend * blend * (3 - 2 * blend)

    local ws = math.max(cfg.finiteNumber(low.surface, 0.10)
        + (cfg.finiteNumber(high.surface, 0.10) - cfg.finiteNumber(low.surface, 0.10)) * blend, 0)
    local w1 = math.max(cfg.finiteNumber(low.cell1, 0.55)
        + (cfg.finiteNumber(high.cell1, 0.55) - cfg.finiteNumber(low.cell1, 0.55)) * blend, 0)
    local w2 = math.max(cfg.finiteNumber(low.cell2, 0.35)
        + (cfg.finiteNumber(high.cell2, 0.35) - cfg.finiteNumber(low.cell2, 0.35)) * blend, 0)
    local sum = math.max(ws + w1 + w2, 1e-9)

    return (surface * ws + cell1 * w1 + cell2 * w2) / sum,
        surface, cell1, cell2, ws / sum, w1 / sum, w2 / sum, blend
end

M._wearResearch.getTemperatureMultiplier = function(tempC, profile)
    local cfg = M._wearResearch
    local t = cfg.finiteNumber(tempC, profile and profile.workingTemp or 80)
    local cal = cfg.getThermalWearCalibration(profile) or {}
    local baseHotStart = cfg.finiteNumber(profile and profile.wearOverheatStart,
        cfg.finiteNumber(profile and profile.overheatStart,
            cfg.finiteNumber(profile and profile.workingTemp, 80) + 20))
    local hotStart = baseHotStart + cfg.finiteNumber(cal.hotStartOffsetC, 0)

    if t <= hotStart then return 1.0 end

    local over = t - hotStart
    local points = cal.hotPoints or {{0,1.0},{20,1.1},{50,1.4},{100,2.0}}
    if over <= cfg.finiteNumber(points[1] and points[1][1], 0) then
        return cfg.finiteNumber(points[1] and points[1][2], 1.0)
    end
    for i = 1, #points - 1 do
        local x0 = cfg.finiteNumber(points[i][1], 0)
        local y0 = cfg.finiteNumber(points[i][2], 1.0)
        local x1 = cfg.finiteNumber(points[i + 1][1], x0 + 1)
        local y1 = cfg.finiteNumber(points[i + 1][2], y0)
        if over <= x1 then
            return y0 + (y1 - y0) * cfg.clamp((over - x0) / math.max(x1 - x0, 1e-6), 0, 1)
        end
    end
    return cfg.finiteNumber(points[#points] and points[#points][2], 1.0)
end

-- Research-calibrated transverse contact / shoulder-flex model. Research refs: [R8][R9][R10].
-- Primary-source trends used here:
-- * Yap (SAE 881846): tyre type/size, load and inflation set the transverse
-- vertical-pressure profile; loading mainly changed shoulder pressure while
-- inflation mainly changed centre pressure, with severe local peaks up to ~2x
-- inflation pressure.
-- * Marshek et al. (UT Austin/FHWA Report 386-1, 1985): pressure-film tests
-- showed treaded-tyre pressure peaks in the shoulders at lower inflation;
-- increasing inflation moved the peaks toward the centre, while heavy axle
-- load strongly raised shoulder-region pressure.
-- * Suo et al. (2024): lateral carcass motion separates into translation,
-- bending and torsion; camber shifts load across tyre width.
--
-- We cannot recover the real pressure field or carcass strain tensor from Vehicle
-- Lua, therefore the equations below are deliberately BOUNDED reduced-order maps.
-- They preserve the measured directions of influence without pretending the
-- calibration constants are universal physical tyre constants.
M._crossTreadResearch = {
    enabled = true,
    pressureShapeGain = 0.75,
    pressureRatioExponent = 0.95,
    loadRatioExponent = 0.65,
    complianceExponent = 0.65,
    minShoulderCenterRatio = 0.70,
    maxShoulderCenterRatio = 2.00,
    lateralLoadShiftGain = 0.50,
    maxLateralLoadShiftLog = 0.60,
    flexEdgeGain = 0.65,
    flexComplianceExponent = 1.00,
    maxFlexShoulderCenterRatio = 2.50,
    lateralHysteresisComplianceExponent = 0.65,
    minLateralHysteresisGain = 0.65,
    maxLateralHysteresisGain = 1.65,

    --
    crownSupportRatioByProfile = {
        standard = 0.00,
        sport = 0.80,
        race = 2.00,
        rally_asphalt = 1.25,
        rally_gravel = 0.55,
        drift = 0.00,
    },

    crownLoadCoupling = 0.65,
    crownPressureCoupling = 0.45,

    crownFlexCoupling = 0.75,
}

local GROUND_COOLING_SCALE = 1.0
local GRASS_GROUND_COOLING_SCALE = 10.0

local GRASS_SLIP_HEAT_RATE = 1.0 / 6.0
local WATER_COOLING_MULTIPLIER = 30.0
local WATER_CONTACT_HOLD_SECONDS = 0.20

-- CONTACT-PATCH OWNERSHIP / PROVENANCE NOTE
-- DO NOT replace this with A = Fz / gaugePressure and DO NOT add a separate PSI->cooling multiplier.
-- Pressure is allowed to affect road cooling ONLY through the mechanically resolved footprint below.
--
-- [CP-R1][LITERATURE-DERIVED FORM]
-- Misiewicz, Richards & Godwin, Biosystems Engineering 147 (2016), "Comparison of methods for
-- estimating the carcass stiffness of agricultural tyres on hard surfaces".
-- https://doi.org/10.1016/j.biosystemseng.2016.04.001
-- The paper defines tyre carcass stiffness as an equivalent pressure contribution and discusses
-- mean contact pressure forms Pc = Pi + Pcs and Pc = c1*Pi + Pcs. Importantly, Pcs remains finite
-- at zero inflation, so the simple Fz/Pi membrane approximation must NOT be extrapolated to 0 PSI.
--
-- [CP-R2][PASSENGER-TYRE FE EVIDENCE]
-- Hedayati et al., Vehicles 6(1) (2024), "Modeling and Validation of a Passenger Car Tire Using
-- Finite Element Analysis". https://doi.org/10.3390/vehicles6010016
-- Their validated passenger-tyre FE study shows contact area increases with load and decreasing
-- inflation pressure, and specifically reports nonlinear contact-area behaviour at high load / low pressure.
--
-- [CP-R3][FIRST-ORDER MEMBRANE REFERENCE ONLY]
-- A ~= Fz/Pi is the familiar thin-flexible-membrane first approximation. It remains useful around
-- ordinary inflation/load but omits carcass/belt support and large-deformation geometry; it is NOT
-- the low-pressure model used here.
--
-- [CP-E1][KTS RESEARCH-GUIDED ENGINEERING DEFAULT]
-- 30 kPa is the reference equivalent carcass-support pressure at 100% sidewall spring and 50% aspect.
-- It is NOT a universal measured passenger-tyre constant. Live KTS sidewall stiffness and aspect ratio
-- scale it so hot/soft or tall sidewalls support less mean pressure while stiff/low-profile constructions
-- support more. The pneumatic coefficient is normalized so a reference tyre still resolves to the legacy
-- 30 PSI footprint at KTS's OPTIMAL_PRESSURE; this preserves solved normal-pressure calibration.
--
-- [CP-E2][KTS LARGE-DEFORMATION GEOMETRY DEFAULT]
-- The maximum footprint is limited by the chord available when crown deflection approaches the
-- sidewall height (rim/inner-carcass geometric regime). width*chord*0.45 converts the bounding rectangle
-- into a representative rounded/loaded footprint. 0.45 and the n=4 smooth-min exponent are KTS modelling
-- choices, not paper-measured universal constants. Their job is to remove the Fz/P -> infinity singularity
-- without disturbing the ordinary-pressure range.
-- SCOPE NOTE:
-- Keep the contact-patch calibration in an existing module table rather than as
-- top-level `local` variables. BeamNG's Lua/LuaJIT compiler has a hard limit of
-- 200 simultaneously-active locals per function/chunk; this large legacy module
-- already sits close to that ceiling. Adding future top-level locals here can make
-- the ENTIRE auto extension fail to compile and can cascade into other auto-loaded
-- mods/actions not registering. Do not unpack these fields back into top-level locals.
M._physicalThermal.contactPatchModel = {
    carcassReferencePressurePa = 30000.0,
    carcassReferenceAspect = 0.50,
    carcassAspectExponent = 0.35,
    pneumaticPressureCoeff = (OPTIMAL_PRESSURE - 30000.0) / OPTIMAL_PRESSURE,
    maxFootprintShapeFactor = 0.45,
    saturationExponent = 4.0,
    logGain = 100000,
    deadzoneRatio = 0.002,
    groundCoolingMaxFactor = 1.35,
}

-- Road-refresh thermal model with stationary-noise gating, wheel-oriented slip
-- kinematics and contact-patch flash memory. Research refs: [R1][R2][R3][R4].
--
-- The macro tread temperature remains the main compound temperature. The separate
-- flash_temp is the much faster asperity/contact temperature. Grip no longer uses
-- the old "locked for X seconds" penalty; instead it estimates how much sliding
-- history the rubber currently inside the footprint has accumulated before wheel
-- rotation replaces it with fresh circumference.
--
-- For a rolling tread element the simplified Persson-style cold->hot transition is
-- The model uses two separate mechanisms instead of treating wheel-centre slip as hot-patch %:
-- (1) a brush adhesion/sliding gate estimates the loaded fraction of the footprint
-- that has actually crossed into local sliding;
-- (2) Hmem(s)=1-exp(-s/s0), averaged over one footprint pass, describes flash-history
-- maturation only INSIDE that sliding region.
-- The final hot-branch target is H = slidingLoadFraction * HmemAvg. This keeps H near
-- zero through ordinary elastic tread shear, then grows it progressively near the
-- friction limit. Full lock/wheelspin/drift converge to the full flash-memory response.
-- IMPORTANT: the tyre-profile working-temperature curve belongs to the
-- MACRO/background tread state only. flash_temp is a microscopic transient and is
-- no longer evaluated as though the whole tyre had reached that absolute temperature.
-- Instead only the positive flash rise above macro tread is mapped through a compressed
-- hot-side equivalent-temperature curve. This prevents cold rubber from jumping onto
-- the profile's optimum-temperature branch simply because a sliding asperity is hot.
-- The modern model-owned curve compares the complete research patch target against
-- BeamNG's reconstructed native static->sliding Stribeck state and may correct in
-- either direction after the peak gate; flash remains a separate fast thermal state.
--
-- the old HUD-only circumferential `hotspotStrength` timer has been removed.
-- Physical circumferential heat/wear memory now lives in M._circumferential as conserved
-- sparse angular energy/wear features. The flash-history model below remains separate:
-- it describes microscopic slip-distance maturation inside the current contact patch.
M._flashMemory = {
    slipMemoryLengthM = 0.0030,

    --
    brushCriticalSigmaX = 0.110804,
    brushCriticalSigmaYByProfile = {
        standard = 0.250259,
        sport = 0.176327,
        race = 0.140541,
        rally_asphalt = 0.158384,
        rally_gravel = 0.258618,
        drift = 0.202420,
    },
    brushCriticalSigmaYFallback = 0.225072,

    brushCriticalThermalScaleMin = 0.80,
    brushMinSurfaceSpeedMps = 0.05,

    mechanicalResearchOnsetB = 0.08,
    mechanicalResearchFullB = 0.30,

    nativeStribeckDeembedEnabled = true,
    nativeStribeckDefaultExponent = 1.75,
    nativeStribeckDefaultVelMult = 1.0,
    nativeStribeckFallbackVelocityMps = 6.0,
    nativeStribeckFallbackStaticMu = 1.00,
    nativeStribeckFallbackSlidingMu = 0.70,
    nativeDeembedMinMultiplier = 0.60,
    nativeDeembedMaxMultiplier = 1.55,

    mechanicalSlipRemapMaxMultiplier = 1.65,

    flashLocalToBulkEquivalentScale = 0.15,

    minSlipSpeedMps = 0.03,
    minRefreshSpeedMps = 0.05,
    buildTauFloorS = 0.002,
    buildTauCeilS = 0.030,
    thermalReleaseTauS = 0.010,
    minGripMultiplier = 0.25,
}

--
--
--
--
local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function finiteNumber(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

local function applyEnvironmentTemperatureC(ambientC)
    ambientC = tonumber(ambientC)
    if ambientC == nil or ambientC ~= ambientC or ambientC == math.huge or ambientC == -math.huge then
        return false
    end
    if ambientC < -100 or ambientC > 100 then return false end
    ENV_TEMP = ambientC
    ROAD_TEMP = ambientC + ROAD_TEMP_OFFSET_C
    got_env_temp = true
    return true
end

local function syncEnvironmentTemperatureFromVehicle()
    if not obj or not obj.getEnvTemperature then return false end
    local ok, tempK = pcall(function() return obj:getEnvTemperature() end)
    if not ok then return false end
    local valueK = tonumber(tempK)
    if valueK == nil or valueK ~= valueK or valueK == math.huge or valueK == -math.huge then
        return false
    end
    return applyEnvironmentTemperatureC(valueK - 273.15)
end

local function syncEnvironmentTemperatureFromMailbox()
    if not obj or not obj.getLastMailbox then return false end
    return applyEnvironmentTemperatureC(obj:getLastMailbox("tyreWearMailboxEnvTemp"))
end

local TempRingsToAvgTemp

M._treadGrooveGeometry = M._treadGrooveGeometry or {}

M._treadGrooveGeometry.getReserveM = function(physical, nominalDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local fallback = finiteNumber(M._tread1D and M._tread1D.nonWearableReserveM, 0.00050)
    local requested = math.max(finiteNumber(physical and physical.structuralReserveM, fallback), 0.00010)
    return clamp(requested, 0.00010, nominal * 0.35)
end

M._treadGrooveGeometry.getFreshGrooveDepthM = function(physical, nominalDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local reserve = M._treadGrooveGeometry.getReserveM(physical, nominal)
    local surfaceVoid = clamp(finiteNumber(physical and physical.treadVoidRatio, 0), 0, 0.60)
    if surfaceVoid <= 0 then return 0 end
    return clamp(finiteNumber(physical and physical.freshGrooveDepthM, nominal - reserve), 0, math.max(nominal - reserve, 0))
end

M._treadGrooveGeometry.voidAtOriginalDepth = function(physical, originalDepthM, nominalDepthM)
    local surfaceVoid = clamp(finiteNumber(physical and physical.treadVoidRatio, 0), 0, 0.60)
    local grooveDepth = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, nominalDepthM)
    if surfaceVoid <= 0 or grooveDepth <= 1e-9 then return 0 end
    local d = finiteNumber(originalDepthM, 0)
    if d < 0 or d > grooveDepth then return 0 end
    local floorVoid = clamp(finiteNumber(physical and physical.grooveFloorVoidRatio, surfaceVoid), 0, surfaceVoid)
    local u = clamp(d / grooveDepth, 0, 1)
    return surfaceVoid + (floorVoid - surfaceVoid) * u
end

M._treadGrooveGeometry.integratedVoidThicknessM = function(physical, depthA, depthB, nominalDepthM)
    local a = math.min(finiteNumber(depthA, 0), finiteNumber(depthB, 0))
    local b = math.max(finiteNumber(depthA, 0), finiteNumber(depthB, 0))
    if b <= a then return 0 end
    local surfaceVoid = clamp(finiteNumber(physical and physical.treadVoidRatio, 0), 0, 0.60)
    local grooveDepth = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, nominalDepthM)
    if surfaceVoid <= 0 or grooveDepth <= 1e-9 then return 0 end
    local floorVoid = clamp(finiteNumber(physical and physical.grooveFloorVoidRatio, surfaceVoid), 0, surfaceVoid)
    local lo = clamp(a, 0, grooveDepth)
    local hi = clamp(b, 0, grooveDepth)
    if hi <= lo then return 0 end
    local slope = (floorVoid - surfaceVoid) / grooveDepth
    return surfaceVoid * (hi - lo) + 0.5 * slope * (hi * hi - lo * lo)
end

M._treadGrooveGeometry.averageVoidBetween = function(physical, depthA, depthB, nominalDepthM)
    local a = math.min(finiteNumber(depthA, 0), finiteNumber(depthB, 0))
    local b = math.max(finiteNumber(depthA, 0), finiteNumber(depthB, 0))
    local span = math.max(b - a, 1e-9)
    return clamp(M._treadGrooveGeometry.integratedVoidThicknessM(physical, a, b, nominalDepthM) / span, 0, 0.60)
end

M._treadGrooveGeometry.getWearDepthM = function(nominalDepthM, remainingDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 0, nominal)
    return math.max(nominal - remaining, 0)
end

M._treadGrooveGeometry.getCurrentSurfaceVoidRatio = function(physical, nominalDepthM, remainingDepthM)
    local wear = M._treadGrooveGeometry.getWearDepthM(nominalDepthM, remainingDepthM)
    local liveVoid = M._treadGrooveGeometry.voidAtOriginalDepth(physical, wear, nominalDepthM)
    -- [TG-E8]: an ideal linear taper with a finite floor width would hold
    -- that floor void until the final micron, then jump instantly to solid rubber.
    -- Blend only the LIVE opening through the final 0.25 mm (road profiles opt in);
    -- integrated groove volume/cell mass remains the exact depth integral above.
    local closureBlendM = math.max(finiteNumber(physical and physical.grooveClosureBlendM, 0), 0)
    if liveVoid > 0 and closureBlendM > 1e-9 then
        local grooveDepth = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, nominalDepthM)
        local activeDepth = math.max(grooveDepth - wear, 0)
        if activeDepth < closureBlendM then
            local u = clamp(activeDepth / closureBlendM, 0, 1)
            local smooth = u * u * (3 - 2 * u)
            liveVoid = liveVoid * smooth
        end
    end
    return clamp(liveVoid, 0, 0.60)
end

M._treadGrooveGeometry.getCurrentZoneSurfaceVoidRatio = function(physical, zone, nominalDepthM, remainingDepthM)
    local freshByZone = physical and physical.coolingZoneFreshVoidRatios
    if type(freshByZone) ~= "table" then
        return M._treadGrooveGeometry.getCurrentSurfaceVoidRatio(physical, nominalDepthM, remainingDepthM)
    end
    local z = clamp(math.floor(finiteNumber(zone, 2)), 1, 3)
    local surfaceVoid = clamp(finiteNumber(freshByZone[z], physical.treadVoidRatio), 0, 0.60)
    local grooveDepth = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, nominalDepthM)
    if surfaceVoid <= 0 or grooveDepth <= 1e-9 then return 0 end
    local wear = M._treadGrooveGeometry.getWearDepthM(nominalDepthM, remainingDepthM)
    if wear < 0 or wear > grooveDepth then return 0 end
    local floorByZone = physical and physical.coolingZoneFloorVoidRatios
    local floorVoid = clamp(finiteNumber(type(floorByZone)=="table" and floorByZone[z] or nil, physical.grooveFloorVoidRatio or surfaceVoid), 0, surfaceVoid)
    local u = clamp(wear / grooveDepth, 0, 1)
    local liveVoid = surfaceVoid + (floorVoid - surfaceVoid) * u
    local closureBlendM = math.max(finiteNumber(physical and physical.grooveClosureBlendM, 0), 0)
    if liveVoid > 0 and closureBlendM > 1e-9 then
        local activeDepth = math.max(grooveDepth - wear, 0)
        if activeDepth < closureBlendM then
            local c = clamp(activeDepth / closureBlendM, 0, 1)
            liveVoid = liveVoid * c * c * (3 - 2 * c)
        end
    end
    return clamp(liveVoid, 0, 0.60)
end

M._treadGrooveGeometry.updateCoolingZoneShares = function(data, physical, geom, contactWeights)
    data._coolingZoneVoidScratch = type(data._coolingZoneVoidScratch)=="table" and data._coolingZoneVoidScratch or {0,0,0}
    data._coolingZoneAirScratch = type(data._coolingZoneAirScratch)=="table" and data._coolingZoneAirScratch or {1/3,1/3,1/3}
    data._coolingZoneGroundScratch = type(data._coolingZoneGroundScratch)=="table" and data._coolingZoneGroundScratch or {1/3,1/3,1/3}
    local voids, airShares, groundShares = data._coolingZoneVoidScratch, data._coolingZoneAirScratch, data._coolingZoneGroundScratch
    local freshByZone = physical and physical.coolingZoneFreshVoidRatios
    local hasAsymmetry = type(freshByZone)=="table"
    local airSum, groundSum = 0, 0
    for z=1,3 do
        local remaining = finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[z], geom.nominalTreadDepth)
        voids[z] = M._treadGrooveGeometry.getCurrentZoneSurfaceVoidRatio(physical,z,geom.nominalTreadDepth,remaining)
        local activeDepth = M._treadGrooveGeometry.getCurrentActiveGrooveDepthM(physical,geom.nominalTreadDepth,remaining)
        local freshVoid = hasAsymmetry and clamp(finiteNumber(freshByZone[z], physical.treadVoidRatio),0,0.60) or 1
        airShares[z] = hasAsymmetry and math.max(freshVoid * activeDepth, 0) or 1
        local land = clamp(1-voids[z],0.05,1)
        local localGroundScale = hasAsymmetry
            and (land ^ (1-clamp(finiteNumber(physical.roadGroundContactPressureExponent,1),0,1))) or 1
        groundShares[z] = math.max(finiteNumber(contactWeights and contactWeights[z],1/3),0) * localGroundScale
        airSum = airSum + airShares[z]; groundSum = groundSum + groundShares[z]
    end
    if airSum <= 1e-12 then airShares[1],airShares[2],airShares[3]=1/3,1/3,1/3 else for z=1,3 do airShares[z]=airShares[z]/airSum end end
    if groundSum <= 1e-12 then groundShares[1],groundShares[2],groundShares[3]=1/3,1/3,1/3 else for z=1,3 do groundShares[z]=groundShares[z]/groundSum end end
    geom.zoneSurfaceVoidRatio=voids; geom.grooveForcedAirZoneShare=airShares; geom.groundCoolingZoneShare=groundShares
    return voids,airShares,groundShares
end

M._treadGrooveGeometry.getCurrentVolumeVoidRatio = function(physical, nominalDepthM, remainingDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 1e-9, nominal)
    local wear = nominal - remaining
    return clamp(M._treadGrooveGeometry.integratedVoidThicknessM(physical, wear, nominal, nominal) / remaining, 0, 0.60)
end

M._treadGrooveGeometry.getCellRubberFillFraction = function(physical, nominalDepthM, remainingDepthM, cellIndex, cellCount)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 1e-9, nominal)
    local n = math.max(math.floor(finiteNumber(cellCount, 12)), 1)
    local j = clamp(math.floor(finiteNumber(cellIndex, 1)), 1, n)
    local wear = nominal - remaining
    local dx = remaining / n
    local a = wear + (j - 1) * dx
    local b = a + dx
    return clamp(1 - M._treadGrooveGeometry.averageVoidBetween(physical, a, b, nominal), 0.05, 1.0)
end

M._treadGrooveGeometry.getInterfaceRubberFillFraction = function(physical, nominalDepthM, remainingDepthM, interfaceIndex, cellCount)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 1e-9, nominal)
    local n = math.max(math.floor(finiteNumber(cellCount, 12)), 1)
    local i = clamp(math.floor(finiteNumber(interfaceIndex, 1)), 1, math.max(n - 1, 1))
    local wear = nominal - remaining
    local depth = wear + i * remaining / n
    return clamp(1 - M._treadGrooveGeometry.voidAtOriginalDepth(physical, depth, nominal), 0.05, 1.0)
end

-- variable-cell groove helpers. Bounds are measured from the CURRENT
-- road surface; convert them back to original fresh-tread depth before integrating
-- the already-solved tapered groove geometry.
M._treadGrooveGeometry.getRubberFillFractionOverLiveDepth = function(physical, nominalDepthM, remainingDepthM, liveA, liveB)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 1e-9, nominal)
    local a = clamp(math.min(finiteNumber(liveA,0), finiteNumber(liveB,0)), 0, remaining)
    local b = clamp(math.max(finiteNumber(liveA,0), finiteNumber(liveB,0)), 0, remaining)
    if b <= a then return 1 end
    local wear = nominal - remaining
    return clamp(1 - M._treadGrooveGeometry.averageVoidBetween(physical, wear + a, wear + b, nominal), 0.05, 1.0)
end

M._treadGrooveGeometry.getInterfaceRubberFillAtLiveDepth = function(physical, nominalDepthM, remainingDepthM, liveDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local remaining = clamp(finiteNumber(remainingDepthM, nominal), 1e-9, nominal)
    local wear = nominal - remaining
    local d = wear + clamp(finiteNumber(liveDepthM,0), 0, remaining)
    return clamp(1 - M._treadGrooveGeometry.voidAtOriginalDepth(physical, d, nominal), 0.05, 1.0)
end

M._treadGrooveGeometry.getCurrentActiveGrooveDepthM = function(physical, nominalDepthM, remainingDepthM)
    local grooveDepth = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, nominalDepthM)
    local wear = M._treadGrooveGeometry.getWearDepthM(nominalDepthM, remainingDepthM)
    return math.max(grooveDepth - wear, 0)
end

M._circumferential = {
    enabled = true,
    modelVersion = "sparse-circumferential-v4-four-depth-single-road-owner",
    maxThermalFeatures = 12,
    maxWearFeatures = 12,
    localDepthSpans = {1, 2, 3, 4},
    localDepthCount = 4,
    minHalfWidthTurns = 0.004,
    maxHalfWidthTurns = 0.48,
    foldHalfWidthTurns = 0.42,
    mergeDistanceScale = 0.70,
    sweepAverageStartTurns = 0.45,
    sweepAverageFullTurns = 1.00,
    hotspotLocalizationWindowS = 0.080,
    hotspotRouteFullTurnsPerWindow = 0.10,
    hotspotRouteZeroTurnsPerWindow = 0.50,
    foldPeakDeltaC = 0.20,
    foldMinAgeS = 0.35,
    minFeatureEnergyJ = 0.05,
    thermalDiffusivityScale = 1.0,
    hotspotHudDeltaC = 90.0,
}

M._circumferential.wrap01 = function(x)
    x = finiteNumber(x, 0) % 1
    if x < 0 then x = x + 1 end
    return x
end

M._circumferential.signedPhaseDelta = function(a, b)
    return ((M._circumferential.wrap01(a) - M._circumferential.wrap01(b) + 0.5) % 1) - 0.5
end

M._circumferential.kernel = function(samplePhase, featurePhase, halfWidthTurns)
    local w = clamp(finiteNumber(halfWidthTurns, M._circumferential.minHalfWidthTurns),
        M._circumferential.minHalfWidthTurns, M._circumferential.maxHalfWidthTurns)
    local d = math.abs(M._circumferential.signedPhaseDelta(samplePhase, featurePhase))
    if d >= w then return 0 end
    return 0.5 * (1 + math.cos(math.pi * d / w))
end

M._circumferential.smoothstep01 = function(x)
    x = clamp(finiteNumber(x, 0), 0, 1)
    return x * x * (3 - 2 * x)
end

M._circumferential.getLayerCellRange = function(layerIndex, cellCount)
    local cfg=M._circumferential
    local n=math.max(math.floor(finiteNumber(cellCount,M._tread1D and M._tread1D.cells or 12)),1)
    local first=1
    for i=1,math.max(math.floor(finiteNumber(layerIndex,1))-1,0) do first=first+math.max(math.floor(finiteNumber(cfg.localDepthSpans[i],1)),1) end
    if first>n then return n+1,n,0 end
    local span=math.max(math.floor(finiteNumber(cfg.localDepthSpans[layerIndex],1)),1)
    local last=math.min(first+span-1,n)
    return first,last,math.max(last-first+1,0)
end

M._circumferential.ensurePendingCells = function(state, cellCount)
    local n = math.max(math.floor(finiteNumber(cellCount, M._tread1D and M._tread1D.cells or 12)), 1)
    state.pendingBulkCellEnergyJ = type(state.pendingBulkCellEnergyJ) == "table"
        and state.pendingBulkCellEnergyJ or {}
    for z = 1, 3 do
        state.pendingBulkCellEnergyJ[z] = type(state.pendingBulkCellEnergyJ[z]) == "table"
            and state.pendingBulkCellEnergyJ[z] or {}
        for j = 1, n do
            state.pendingBulkCellEnergyJ[z][j] = finiteNumber(state.pendingBulkCellEnergyJ[z][j], 0)
        end
    end
    if type(state.pendingBulkEnergyJ) == "table" then
        for z = 1, 3 do
            state.pendingBulkCellEnergyJ[z][1] = state.pendingBulkCellEnergyJ[z][1]
                + finiteNumber(state.pendingBulkEnergyJ[z], 0)
        end
        state.pendingBulkEnergyJ = nil
    end
    return state.pendingBulkCellEnergyJ
end

M._circumferential.ensureFeatureSchema = function(feature)
    local cfg = M._circumferential
    feature = type(feature) == "table" and feature or {}
    feature.phase = cfg.wrap01(feature.phase)
    feature.ageS = math.max(finiteNumber(feature.ageS, 0), 0)
    feature.layers = type(feature.layers) == "table" and feature.layers or {}
    local legacy = type(feature.energyJ) == "table" and feature.energyJ or nil
    local legacyWidth = clamp(finiteNumber(feature.halfWidthTurns, cfg.minHalfWidthTurns),
        cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    for l = 1, cfg.localDepthCount do
        local layer = type(feature.layers[l]) == "table" and feature.layers[l] or {}
        local existingEnergy = type(layer.energyJ) == "table" and layer.energyJ or nil
        layer.energyJ = existingEnergy or {}
        for z = 1, 3 do
            local migrated = (l == 1 and legacy) and finiteNumber(legacy[z], 0) or 0
            layer.energyJ[z] = existingEnergy and finiteNumber(existingEnergy[z], 0) or migrated
        end
        layer.halfWidthTurns = clamp(finiteNumber(layer.halfWidthTurns, legacyWidth),
            cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
        feature.layers[l] = layer
    end
    feature.energyJ = nil
    feature.halfWidthTurns = nil
    return feature
end

M._circumferential.ensureState = function(data)
    data.circumferential_state = type(data.circumferential_state) == "table"
        and data.circumferential_state or {}
    local s = data.circumferential_state
    s.phase = M._circumferential.wrap01(s.phase)
    s.previousPhase = M._circumferential.wrap01(s.previousPhase or s.phase)
    s.deltaTurns = math.max(finiteNumber(s.deltaTurns, 0), 0)
    s.direction = finiteNumber(s.direction, 1) >= 0 and 1 or -1
    s.thermalFeatures = type(s.thermalFeatures) == "table" and s.thermalFeatures or {}
    s.wearFeatures = type(s.wearFeatures) == "table" and s.wearFeatures or {}
    s.activeCellCountByZone = type(data.tread_active_cell_count)=="table"
        and {math.max(math.floor(finiteNumber(data.tread_active_cell_count[1],12)),1),
             math.max(math.floor(finiteNumber(data.tread_active_cell_count[2],12)),1),
             math.max(math.floor(finiteNumber(data.tread_active_cell_count[3],12)),1)}
        or {M._tread1D and M._tread1D.cells or 12,M._tread1D and M._tread1D.cells or 12,M._tread1D and M._tread1D.cells or 12}
    M._circumferential.ensurePendingCells(s, M._tread1D and M._tread1D.cells or 12)
    for i = 1, #s.thermalFeatures do
        s.thermalFeatures[i] = M._circumferential.ensureFeatureSchema(s.thermalFeatures[i])
    end
    return s
end

M._circumferential.clearThermal = function(data)
    if type(data) ~= "table" then return end
    local s = M._circumferential.ensureState(data)
    s.thermalFeatures = {}
    s.pendingBulkEnergyJ = nil
    s.pendingBulkCellEnergyJ = {}
    M._circumferential.ensurePendingCells(s, M._tread1D and M._tread1D.cells or 12)
    data.circumferential_contact_surface_temp_zone_c = nil
    data.circumferential_contact_surface_temp_c = nil
    data.circumferential_contact_grip_depth_temp_c = nil
    data.circumferential_contact_grip_depth_delta_c = 0
    data.circumferential_contact_layer_delta_c = nil
    data.circumferential_contact_layer_delta_zone_c = nil
    data.circumferential_local_layer_energy_j = nil
    data.circumferential_contact_tread_cell1_temp_zone_c = nil
    data.circumferential_contact_tread_cell2_temp_zone_c = nil
    data.circumferential_mean_surface_temp_c = nil
    data.circumferential_hotspot_contact = 0
    data.circumferential_hotspot_strength = 0
    data.circumferential_coldspot_contact = 0
    data.circumferential_coldspot_strength = 0
    data.circumferential_coldspot_peak_drop_c = 0
    data.circumferential_coldspot_contact_drop_c = 0
    data.circumferential_coldspot_energy_j = 0
    data.circumferential_thermal_abs_energy_j = 0
    data.circumferential_resolution_local_fraction = 0
    data.circumferential_angular_localization = 0
    data.circumferential_rotation_turns_window = 0
    data.circumferential_angular_speed_rad_s = 0
    data.circumferential_wheel_surface_speed_mps = 0
    data.circumferential_local_fraction = 0
    data.circumferential_heat_local_fraction = 0
    data.circumferential_thermal_feature_count = 0
end

M._circumferential.beginStep = function(data, angularVelocity, dt, geom)
    local s = M._circumferential.ensureState(data)
    local elapsedDt = math.max(finiteNumber(dt, 0), 0)
    local omega = finiteNumber(angularVelocity, 0)
    s.previousPhase = M._circumferential.wrap01(s.phase)
    s.direction = omega < 0 and -1 or 1
    s.deltaTurns = math.abs(omega) * elapsedDt / (2 * math.pi)
    s.phase = M._circumferential.wrap01(s.previousPhase + s.direction * s.deltaTurns)

    local startTurns = math.max(finiteNumber(M._circumferential.sweepAverageStartTurns, 0.45), 0)
    local fullTurns = math.max(finiteNumber(M._circumferential.sweepAverageFullTurns, 1.0), startTurns + 1e-6)
    local blend = 0
    if s.deltaTurns > startTurns then
        blend = M._circumferential.smoothstep01((s.deltaTurns - startTurns) / (fullTurns - startTurns))
    end
    s.averageBlend = clamp(blend, 0, 1)

    local radius = math.max(finiteNumber(geom and geom.safeRadius, data.tyre_radius_m or 0.33), 0.01)
    local absOmega = math.abs(omega)
    local wheelSurfaceSpeedMps = absOmega * radius

    local localizationWindowS = math.max(
        finiteNumber(M._circumferential.hotspotLocalizationWindowS, 0.080), 1e-4)
    local fullTurnsWindow = math.max(
        finiteNumber(M._circumferential.hotspotRouteFullTurnsPerWindow, 0.10), 0)
    local zeroTurnsWindow = math.max(
        finiteNumber(M._circumferential.hotspotRouteZeroTurnsPerWindow, 0.50),
        fullTurnsWindow + 1e-6)
    local turnsOverWindow = absOmega * localizationWindowS / (2 * math.pi)
    local angularLocalization = 0
    if turnsOverWindow <= fullTurnsWindow then
        angularLocalization = 1
    elseif turnsOverWindow < zeroTurnsWindow then
        angularLocalization = M._circumferential.smoothstep01(
            (zeroTurnsWindow - turnsOverWindow) / (zeroTurnsWindow - fullTurnsWindow))
    end

    s.resolutionLocalFraction = M._circumferential.enabled and (1 - s.averageBlend) or 0
    s.angularLocalization = M._circumferential.enabled and clamp(angularLocalization, 0, 1) or 0
    s.turnsOverLocalizationWindow = turnsOverWindow
    s.angularSpeedRadS = absOmega
    s.wheelSurfaceSpeedMps = wheelSurfaceSpeedMps
    s.localFraction = s.resolutionLocalFraction
    s.heatLocalFraction = s.resolutionLocalFraction * s.angularLocalization

    local circumference = math.max(2 * math.pi * radius, 0.01)
    local patchFraction = clamp(
        finiteNumber(geom and geom.footprintLength, data.contact_patch_length_m or 0.08) / circumference,
        0.002, 0.35)
    local baseHalfWidth = math.max(M._circumferential.minHalfWidthTurns, patchFraction * 0.55)
    local representedSweep = math.min(s.deltaTurns, M._circumferential.sweepAverageFullTurns)
    s.depositHalfWidthTurns = clamp(baseHalfWidth + 0.5 * representedSweep,
        M._circumferential.minHalfWidthTurns, M._circumferential.maxHalfWidthTurns)
    s.depositPhase = M._circumferential.wrap01(
        s.previousPhase + s.direction * 0.5 * math.min(s.deltaTurns, 1.0))
    s.patchFraction = patchFraction
    return s
end

M._circumferential.featureEnergy = function(feature)
    local cfg = M._circumferential
    feature = cfg.ensureFeatureSchema(feature)
    local total = 0
    for l = 1, cfg.localDepthCount do
        for z = 1, 3 do total = total + math.abs(finiteNumber(feature.layers[l].energyJ[z], 0)) end
    end
    return total
end

M._circumferential.queueBulkCellEnergy = function(state, zone, cell, energyJ, cellCount)
    local z = clamp(math.floor(finiteNumber(zone, 1)), 1, 3)
    local n = type(cellCount)=="table" and math.max(math.floor(finiteNumber(cellCount[z],12)),1)
        or math.max(math.floor(finiteNumber(cellCount,12)),1)
    local pending = M._circumferential.ensurePendingCells(state, math.max(n,M._tread1D and M._tread1D.cells or n))
    local j = clamp(math.floor(finiteNumber(cell, 1)), 1, n)
    pending[z][j] = finiteNumber(pending[z][j], 0) + finiteNumber(energyJ, 0)
end

M._circumferential.queueLayerEnergyToBulk = function(state, layerIndex, zone, energyJ, cellCount)
    local z=clamp(math.floor(finiteNumber(zone,1)),1,3)
    local n=type(cellCount)=="table" and math.max(math.floor(finiteNumber(cellCount[z],1)),1)
        or math.max(math.floor(finiteNumber(cellCount,1)),1)
    local first,last,count=M._circumferential.getLayerCellRange(layerIndex,n)
    local e=finiteNumber(energyJ,0)
    if count<=0 then M._circumferential.queueBulkCellEnergy(state,z,n,e,n); return end
    local each=e/count
    for j=first,last do M._circumferential.queueBulkCellEnergy(state,z,j,each,n) end
end

M._circumferential.foldFeatureToBulk = function(state, feature, cellCount)
    local cfg = M._circumferential
    feature = cfg.ensureFeatureSchema(feature)
    for l = 1, cfg.localDepthCount do
        for z = 1, 3 do
            local e = finiteNumber(feature.layers[l].energyJ[z], 0)
            if math.abs(e) > 0 then cfg.queueLayerEnergyToBulk(state, l, z, e, cellCount) end
            feature.layers[l].energyJ[z] = 0
        end
    end
end

M._circumferential.mergeThermalFeature = function(state, phase, halfWidthTurns, zoneEnergyJ)
    local cfg = M._circumferential
    local features = state.thermalFeatures
    local newEnergy = math.abs(finiteNumber(zoneEnergyJ[1], 0))
        + math.abs(finiteNumber(zoneEnergyJ[2], 0))
        + math.abs(finiteNumber(zoneEnergyJ[3], 0))
    if newEnergy <= 0 then return end

    local best, bestDistance = nil, 1
    for _, rawFeature in ipairs(features) do
        local feature = cfg.ensureFeatureSchema(rawFeature)
        local distance = math.abs(cfg.signedPhaseDelta(phase, feature.phase))
        local w = finiteNumber(feature.layers[1].halfWidthTurns, cfg.minHalfWidthTurns)
        local threshold = math.max(cfg.minHalfWidthTurns * 2,
            (w + halfWidthTurns) * cfg.mergeDistanceScale)
        if distance <= threshold and distance < bestDistance then
            best, bestDistance = feature, distance
        end
    end

    if best then
        local oldEnergy = cfg.featureEnergy(best)
        local totalEnergy = math.max(oldEnergy + newEnergy, 1e-9)
        local signedDelta = cfg.signedPhaseDelta(phase, best.phase)
        best.phase = cfg.wrap01(best.phase + signedDelta * (newEnergy / totalEnergy))
        local source = best.layers[1]
        source.halfWidthTurns = clamp(math.max(
            finiteNumber(source.halfWidthTurns, cfg.minHalfWidthTurns),
            halfWidthTurns,
            math.abs(signedDelta) + 0.5 * halfWidthTurns),
            cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
        for z = 1, 3 do source.energyJ[z] = finiteNumber(source.energyJ[z], 0) + finiteNumber(zoneEnergyJ[z], 0) end
        best.ageS = 0
    else
        local feature = {phase = cfg.wrap01(phase), ageS = 0, layers = {}}
        for l = 1, cfg.localDepthCount do
            feature.layers[l] = {halfWidthTurns = clamp(halfWidthTurns, cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns),
                energyJ = {0, 0, 0}}
        end
        for z = 1, 3 do feature.layers[1].energyJ[z] = finiteNumber(zoneEnergyJ[z], 0) end
        table.insert(features, feature)
    end

    while #features > cfg.maxThermalFeatures do
        local weakestIndex, weakestEnergy = 1, math.huge
        for i, feature in ipairs(features) do
            local e = cfg.featureEnergy(feature)
            if e < weakestEnergy then weakestIndex, weakestEnergy = i, e end
        end
        local folded = table.remove(features, weakestIndex)
        if folded then cfg.foldFeatureToBulk(state, folded, state.activeCellCountByZone or (M._tread1D and M._tread1D.cells or 12)) end
    end
end

-- signed circumferential surface-energy source.
--
-- [RC-R1][LITERATURE-DERIVED PHYSICS]
-- Tyre/road heat exchange is a LOCAL footprint boundary, not a whole-circumference
-- temperature sink. Representative tyre thermal modelling resolves road/tread
-- exchange at the road-facing tread boundary/contact patch:
-- https://www.mdpi.com/2076-3417/13/21/11996
--
-- [RC-E1][KTS ENGINEERING REPRESENTATION]
-- DO NOT create a second "coldspot" model. Positive friction heat and negative
-- road-cooling Joules use the SAME sparse circumferential feature, phase kernel,
-- four depth slabs, radial Fourier exchange, circumferential diffusion, merging,
-- and conservative fold-to-bulk path. This prevents heating and cooling from
-- developing incompatible spatial memories and lets road cooling directly cancel
-- an existing hotspot when both act on the same material sector.
--
-- zoneEnergyJ is already the LOCAL signed energy for this solver step:
-- positive = heat added to road-side slab 1
-- negative = heat removed from road-side slab 1
M._circumferential.depositSignedSurfaceZoneEnergy = function(data, zoneEnergyJ)
    local cfg = M._circumferential
    local state = cfg.ensureState(data)
    if not cfg.enabled or type(zoneEnergyJ) ~= "table" then return 0 end

    local signed = {0, 0, 0}
    local magnitude = 0
    for z = 1, 3 do
        signed[z] = finiteNumber(zoneEnergyJ[z], 0)
        magnitude = magnitude + math.abs(signed[z])
    end
    if magnitude <= 0 then return 0 end

    if magnitude <= cfg.minFeatureEnergyJ then
        for z = 1, 3 do
            cfg.queueBulkCellEnergy(state, z, 1, signed[z], state.activeCellCountByZone or (M._tread1D and M._tread1D.cells or 12))
        end
        return magnitude
    end
    cfg.mergeThermalFeature(state, state.depositPhase, state.depositHalfWidthTurns, signed)
    return magnitude
end

M._circumferential.depositHeat = function(data, totalEnergyJ, zoneWeights)
    local cfg = M._circumferential
    local state = cfg.ensureState(data)
    local energy = math.max(finiteNumber(totalEnergyJ, 0), 0)
    if not cfg.enabled or finiteNumber(state.heatLocalFraction, 0) <= 0 or energy <= 0 then return end

    local zoneEnergy = {0, 0, 0}
    local weightSum = 0
    for z = 1, 3 do weightSum = weightSum + math.max(finiteNumber(zoneWeights and zoneWeights[z], 0), 0) end
    if weightSum <= 1e-9 then weightSum = 1 end
    for z = 1, 3 do
        zoneEnergy[z] = energy * math.max(finiteNumber(zoneWeights and zoneWeights[z], 1 / 3), 0) / weightSum
    end
    cfg.depositSignedSurfaceZoneEnergy(data, zoneEnergy)
end

M._circumferential.depositLocalizedRoadBoundary = function(
        data, geom, totalGroundConductance, contactWeights, roadPatchTemp, dt, localFraction, roadPatchCapacityJPerK)
    local cfg = M._circumferential
    local fallbackRoadT = finiteNumber(roadPatchTemp, ROAD_TEMP)
    if type(cfg.zoneThermalGeometry) ~= "function" or type(cfg.layerCapacityFromCells) ~= "function" then
        return 0, fallbackRoadT
    end
    local fraction = clamp(finiteNumber(localFraction, 0), 0, 1)
    local safeDt = clamp(finiteNumber(dt, 0), 0, 0.1)
    if not cfg.enabled or fraction <= 0 or safeDt <= 0 then return 0, fallbackRoadT end

    local zoneEnergy = {0, 0, 0}
    local totalGroundJ = 0
    local roadT = finiteNumber(roadPatchTemp, ROAD_TEMP)
    local roadCap = math.max(finiteNumber(roadPatchCapacityJPerK, 1e9), 0.1)
    for zone = 1, 3 do
        local baseSurfaceT = finiteNumber(data.surface_temp and data.surface_temp[zone], ENV_TEMP)
        local contactT = finiteNumber(
            data.circumferential_contact_surface_temp_zone_c
                and data.circumferential_contact_surface_temp_zone_c[zone],
            baseSurfaceT)
        local zoneG = math.max(finiteNumber(totalGroundConductance, 0), 0)
            * math.max(finiteNumber(geom.groundCoolingZoneShare and geom.groundCoolingZoneShare[zone],
                contactWeights and contactWeights[zone] or (1/3)), 0)
        local n, _, _, _, _, caps = cfg.zoneThermalGeometry(data, geom, zone)
        local c1 = cfg.layerCapacityFromCells(caps, 1, n)
        local support = clamp(finiteNumber(geom.circ and geom.circ.depositHalfWidthTurns, cfg.minHalfWidthTurns),
            cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
        local localCap = math.max(c1 * support, 0.1)
        local q = M._tread1D.exactRCExchangeJ(contactT, localCap, roadT, roadCap,
            zoneG * fraction, safeDt)
        zoneEnergy[zone] = -q
        roadT = roadT + q / roadCap
        totalGroundJ = totalGroundJ + q
    end
    cfg.depositSignedSurfaceZoneEnergy(data, zoneEnergy)
    return totalGroundJ / safeDt, roadT
end

M._circumferential.kernelPrimitive = function(x, halfWidthTurns)
    local cfg = M._circumferential
    local w = clamp(finiteNumber(halfWidthTurns, cfg.minHalfWidthTurns),
        cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    if x <= -w then return 0 end
    if x >= w then return w end
    return 0.5 * (x + w) + 0.5 * w / math.pi * math.sin(math.pi * x / w)
end

M._circumferential.averageKernelOverSweep = function(state, feature, layerIndex)
    local cfg = M._circumferential
    feature = cfg.ensureFeatureSchema(feature)
    local turns = math.max(finiteNumber(state.deltaTurns, 0), 0)
    local layer = feature.layers[clamp(math.floor(finiteNumber(layerIndex, 1)), 1, cfg.localDepthCount)]
    local w = clamp(finiteNumber(layer.halfWidthTurns, cfg.minHalfWidthTurns),
        cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    if turns <= 1e-8 then return cfg.kernel(state.phase, feature.phase, w) end
    if turns >= 1.0 then return w end

    local a = finiteNumber(state.previousPhase, 0)
    local b = a + (finiteNumber(state.direction, 1) >= 0 and turns or -turns)
    local lo, hi = math.min(a, b), math.max(a, b)
    local centre0 = cfg.wrap01(feature.phase)
    local kMin = math.floor(lo - centre0 - w) - 1
    local kMax = math.ceil(hi - centre0 + w) + 1
    local integral = 0
    for k = kMin, kMax do
        local centre = centre0 + k
        integral = integral
            + cfg.kernelPrimitive(hi - centre, w)
            - cfg.kernelPrimitive(lo - centre, w)
    end
    return clamp(integral / math.max(turns, 1e-12), 0, 1)
end

M._circumferential.contactKernel = function(state, feature, layerIndex)
    local cfg = M._circumferential
    feature = cfg.ensureFeatureSchema(feature)
    local layer = feature.layers[clamp(math.floor(finiteNumber(layerIndex, 1)), 1, cfg.localDepthCount)]
    local w = clamp(finiteNumber(layer.halfWidthTurns, cfg.minHalfWidthTurns), cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    local resolved = cfg.kernel(state.phase, feature.phase, w)
    local blend = clamp(finiteNumber(state.averageBlend, 0), 0, 1)
    return lerp(resolved, w, blend)
end

M._circumferential.zoneThermalGeometry = function(data, geom, zone)
    local physical=geom.physicalProfile or {}
    local zoneGeom=geom.zoneCellGeometry and geom.zoneCellGeometry[zone]
    if type(zoneGeom)~="table" then
        zoneGeom=M._tread1D.buildZoneCellGeometry(data,physical,zone,math.max(finiteNumber(geom.treadArea,0.1)/3,1e-5),
            math.max(finiteNumber(geom.rubberDensity,1100),100),math.max(finiteNumber(geom.rubberCp,1900),100))
    end
    local capacitySum,fillSum=0,0
    for j=1,zoneGeom.activeCount do capacitySum=capacitySum+zoneGeom.capacityJPerK[j]; fillSum=fillSum+zoneGeom.fillFraction[j] end
    local meanFill=fillSum/math.max(zoneGeom.activeCount,1); local meanCell=capacitySum/math.max(zoneGeom.activeCount,1)
    local meanDx=zoneGeom.remainingDepthM/math.max(zoneGeom.activeCount,1)
    return zoneGeom.activeCount,meanDx,zoneGeom.areaM2,meanFill,meanCell,zoneGeom.capacityJPerK,zoneGeom
end

M._circumferential.layerCapacityFromCells = function(cellCapacities, layerIndex, cellCount)
    local first, last = M._circumferential.getLayerCellRange(layerIndex, cellCount)
    local capacity = 0
    for j = first, last do capacity = capacity + math.max(finiteNumber(cellCapacities and cellCapacities[j], 0), 0) end
    return math.max(capacity, 0.1)
end

M._circumferential.getBulkLayerTemp = function(data, zone, layerIndex, cellCount)
    local field=data and data.tread_field and data.tread_field[zone] or nil
    if type(field)~="table" then return finiteNumber(data and data.temp and data.temp[zone],ENV_TEMP) end
    local first,last,count=M._circumferential.getLayerCellRange(layerIndex,cellCount)
    if count<=0 then return finiteNumber(field[#field],finiteNumber(data and data.temp and data.temp[zone],ENV_TEMP)) end
    local sum=0; for j=first,last do sum=sum+finiteNumber(field[j],ENV_TEMP) end
    return sum/count
end

M._circumferential.advanceThermal = function(data, geom, totalAirConductance, dt, thermalTick)
    local cfg=M._circumferential; local state=cfg.ensureState(data)
    local result={airW=0,groundW=0,radiationW=0,deepToBulkW=0}
    local safeDt=clamp(finiteNumber(dt,0),0,0.1); local tick=math.max(math.floor(finiteNumber(thermalTick,1)),1)
    if safeDt<=0 or #state.thermalFeatures==0 then return result end
    local radiationAreaZone=math.max(finiteNumber(geom.exposedArea,0),0)/6
    local circumference=math.max(2*math.pi*math.max(finiteNumber(geom.safeRadius,0.33),0.01),0.01)
    local rubberK=math.max(finiteNumber(geom.rubberConductivity,0.25),0.02)
    local diffusivity=rubberK/math.max(finiteNumber(geom.rubberDensity,1100)*finiteNumber(geom.rubberCp,1900),1)*math.max(finiteNumber(cfg.thermalDiffusivityScale,1),0)
    local layerDiv={1,2,4,8}
    for featureIndex=#state.thermalFeatures,1,-1 do
        local feature=cfg.ensureFeatureSchema(state.thermalFeatures[featureIndex]); feature.ageS=math.max(finiteNumber(feature.ageS,0),0)+safeDt
        for l=1,cfg.localDepthCount do
            if tick%layerDiv[l]==0 then
                local layer=feature.layers[l]; local elapsed=safeDt*layerDiv[l]; local w=clamp(finiteNumber(layer.halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns)
                local arc=w*circumference; layer.halfWidthTurns=clamp(math.sqrt(arc*arc+2*diffusivity*elapsed)/circumference,cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns)
            end
        end
        local layerMaxPeak={0,0,0,0}
        for z=1,3 do
            local n,dx,area,fill,cellCapacity,cellCaps,zg=cfg.zoneThermalGeometry(data,geom,z)
            local cap={}; local e={}; local q={0,0,0,0}; local span={}
            for l=1,cfg.localDepthCount do
                local _,_,sp=cfg.getLayerCellRange(l,n); span[l]=sp
                cap[l]=sp>0 and cfg.layerCapacityFromCells(cellCaps,l,n) or 0.1; e[l]=finiteNumber(feature.layers[l].energyJ[z],0)
                if sp<=0 and math.abs(e[l])>0 then cfg.queueLayerEnergyToBulk(state,l,z,e[l],n); e[l]=0; feature.layers[l].energyJ[z]=0 end
            end
            if span[1]>0 then
                local l1=feature.layers[1]; local w1=clamp(finiteNumber(l1.halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns)
                local meanDelta=e[1]/cap[1]; local peakDelta=e[1]/math.max(cap[1]*w1,1e-9); layerMaxPeak[1]=math.max(layerMaxPeak[1],math.abs(peakDelta))
                local airGZone=math.max(finiteNumber(geom.baseAirConductanceEffective,0),0)/3
                    + math.max(finiteNumber(geom.grooveForcedAirConductanceEffective,0),0)
                    * math.max(finiteNumber(geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[z],1/3),0)
                local airW=airGZone*meanDelta; local radW=0
                if math.abs(peakDelta)>1e-9 and radiationAreaZone>0 then
                    local baseSurface=finiteNumber(data.surface_temp and data.surface_temp[z],finiteNumber(data.temp and data.temp[z],ENV_TEMP)); local baseK=math.max(baseSurface+273.15,1); local base4=baseK^4; local sum4=0
                    for sample=1,5 do local x=-1+2*(sample-0.5)/5; local kx=0.5*(1+math.cos(math.pi*math.abs(x))); local localK=math.max(baseSurface+peakDelta*kx+273.15,1); sum4=sum4+(localK^4-base4) end
                    radW=M._physicalThermal.emissivity*M._physicalThermal.stefanBoltzmann*radiationAreaZone*math.min(2*w1,1)*(sum4/5)
                end
                local proposed=(airW+radW)*safeDt; local loss=proposed
                if e[1]~=0 and loss*e[1]>0 and math.abs(loss)>math.abs(e[1]) then loss=e[1] end
                local scale=math.abs(proposed)>1e-12 and loss/proposed or 1; airW=airW*scale; radW=radW*scale; q[1]=q[1]-loss
                result.airW=result.airW+airW; result.radiationW=result.radiationW+radW
            end
            for l=1,cfg.localDepthCount-1 do
                if span[l]>0 and span[l+1]>0 then
                    local div=math.max(layerDiv[l],layerDiv[l+1])
                    if tick%div==0 then
                        local firstA,lastA=cfg.getLayerCellRange(l,n); local firstB,lastB=cfg.getLayerCellRange(l+1,n)
                        local centreA=0.5*(zg.startM[firstA]+zg.endM[lastA]); local centreB=0.5*(zg.startM[firstB]+zg.endM[lastB]); local distance=math.max(centreB-centreA,1e-7)
                        local boundaryDepth=zg.endM[lastA]; local interfaceFill=M._treadGrooveGeometry.getInterfaceRubberFillAtLiveDepth(geom.physicalProfile,geom.nominalTreadDepth,zg.remainingDepthM,boundaryDepth)
                        local G=rubberK*area*interfaceFill/distance
                        local wa=clamp(finiteNumber(feature.layers[l].halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns); local wb=clamp(finiteNumber(feature.layers[l+1].halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns)
                        local ca=math.max(cap[l]*wa,0.1); local cb=math.max(cap[l+1]*wb,0.1); local ta=e[l]/ca; local tb=e[l+1]/cb
                        local transfer=M._tread1D.exactRCExchangeJ(ta,ca,tb,cb,G*math.min(wa,wb),safeDt*div)
                        q[l]=q[l]-transfer; q[l+1]=q[l+1]+transfer
                        if transfer>1e-12 then feature.layers[l+1].halfWidthTurns=math.max(wb,wa) elseif transfer<-1e-12 then feature.layers[l].halfWidthTurns=math.max(wa,wb) end
                    end
                end
            end
            local deep=cfg.localDepthCount; local df,dl,ds=cfg.getLayerCellRange(deep,n)
            if tick%12==0 and ds>0 and dl<n then
                local nextCell=dl+1; local w=clamp(finiteNumber(feature.layers[deep].halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns)
                local localCap=math.max(cap[deep]*w,0.1); local baseT=cfg.getBulkLayerTemp(data,z,deep,n); local localT=baseT+e[deep]/localCap; local bulkT=finiteNumber(data.tread_field[z][nextCell],baseT)
                local distance=math.max(zg.centerM[nextCell]-0.5*(zg.startM[df]+zg.endM[dl]),1e-7); local boundaryFill=M._treadGrooveGeometry.getInterfaceRubberFillAtLiveDepth(geom.physicalProfile,geom.nominalTreadDepth,zg.remainingDepthM,zg.endM[dl]); local G=rubberK*area*boundaryFill/distance
                local transfer=M._tread1D.exactRCExchangeJ(localT,localCap,bulkT,zg.capacityJPerK[nextCell],G*w,safeDt*12)
                q[deep]=q[deep]-transfer; cfg.queueBulkCellEnergy(state,z,nextCell,transfer,n); result.deepToBulkW=result.deepToBulkW+transfer/(safeDt*12)
            end
            for l=1,cfg.localDepthCount do
                if span[l]>0 then
                    local layer=feature.layers[l]; local energy=e[l]+q[l]; local w=clamp(finiteNumber(layer.halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns); local baseT=cfg.getBulkLayerTemp(data,z,l,n)
                    energy=finiteNumber(energy,0)
                    layer.energyJ[z]=energy; layerMaxPeak[l]=math.max(layerMaxPeak[l],math.abs(energy/math.max(cap[l]*w,1e-9)))
                end
            end
        end
        local maxN=math.max(math.floor(finiteNumber(geom.maxActiveTreadCells,geom.treadCells)),1)
        for l=1,cfg.localDepthCount do
            local layer=feature.layers[l]; local absE=0; for z=1,3 do absE=absE+math.abs(finiteNumber(layer.energyJ[z],0)) end
            local fold=absE<=cfg.minFeatureEnergyJ or finiteNumber(layer.halfWidthTurns,0)>=cfg.foldHalfWidthTurns or (feature.ageS>=cfg.foldMinAgeS and layerMaxPeak[l]<cfg.foldPeakDeltaC)
            if fold and absE>0 then for z=1,3 do local zn=geom.activeTreadCellsByZone and geom.activeTreadCellsByZone[z] or maxN; cfg.queueLayerEnergyToBulk(state,l,z,finiteNumber(layer.energyJ[z],0),zn); layer.energyJ[z]=0 end end
        end
        if cfg.featureEnergy(feature)<=cfg.minFeatureEnergyJ then table.remove(state.thermalFeatures,featureIndex) end
    end
    return result
end

M._circumferential.consumePendingBulkEnergy = function(data, cellCountsByZone)
    local state=M._circumferential.ensureState(data); local pending=M._circumferential.ensurePendingCells(state,M._tread1D.cells)
    state.pendingConsumeScratch=type(state.pendingConsumeScratch)=="table" and state.pendingConsumeScratch or {{},{},{}}
    local out=state.pendingConsumeScratch
    for z=1,3 do
        local n=type(cellCountsByZone)=="table" and math.max(math.floor(finiteNumber(cellCountsByZone[z],M._tread1D.cells)),1)
            or math.max(math.floor(finiteNumber(cellCountsByZone,M._tread1D.cells)),1)
        for j=1,n do out[z][j]=finiteNumber(pending[z][j],0); pending[z][j]=0 end
        for j=n+1,#pending[z] do out[z][n]=finiteNumber(out[z][n],0)+finiteNumber(pending[z][j],0); pending[z][j]=0 end
        for j=n+1,#out[z] do out[z][j]=nil end
    end
    return out
end

M._circumferential.consumePendingBulkPower = function(data, dt, cellCount)
    local state = M._circumferential.ensureState(data)
    local n = math.max(math.floor(finiteNumber(cellCount, M._tread1D and M._tread1D.cells or 12)), 1)
    local pending = M._circumferential.ensurePendingCells(state, n)
    local safeDt = math.max(clamp(finiteNumber(dt, 0), 0, 0.1), 1e-6)
    local out = {{}, {}, {}}
    for z = 1, 3 do
        for j = 1, n do
            out[z][j] = finiteNumber(pending[z][j], 0) / safeDt
            pending[z][j] = 0
        end
    end
    return out
end

M._circumferential.refreshContactThermal = function(data, geom, loadBias, contactWeights, thermalCache)
    local cfg=M._circumferential; local state=cfg.ensureState(data)
    local baseFields=(thermalCache and thermalCache.treadField) or data.tread_field; local baseSurface=(thermalCache and thermalCache.surfaceTemp) or data.surface_temp
    local features=thermalCache and thermalCache.circFeatures or state.thermalFeatures
    if type(features)~="table" or #features==0 then
        local surfaceAvg=TempRingsToAvgTemp(baseSurface or data.temp,loadBias,contactWeights)
        local gripAvg=thermalCache and finiteNumber(thermalCache.gripDepthAvgTemp,data.grip_depth_avg_temp)
            or finiteNumber(data.grip_depth_avg_temp,TempRingsToAvgTemp(data.temp,loadBias,contactWeights))
        data._circZeroLayers=data._circZeroLayers or {{0,0,0,0},{0,0,0,0},{0,0,0,0}}
        data._circZeroLayerAvg=data._circZeroLayerAvg or {0,0,0,0}
        data._circZeroEnergy=data._circZeroEnergy or {0,0,0,0}
        data.circumferential_contact_layer_delta_zone_c=data._circZeroLayers; data.circumferential_contact_layer_delta_c=data._circZeroLayerAvg; data.circumferential_local_layer_energy_j=data._circZeroEnergy
        data._circBaseCell1=data._circBaseCell1 or {ENV_TEMP,ENV_TEMP,ENV_TEMP}; data._circBaseCell2=data._circBaseCell2 or {ENV_TEMP,ENV_TEMP,ENV_TEMP}; data._circBaseCell3=data._circBaseCell3 or {ENV_TEMP,ENV_TEMP,ENV_TEMP}
        for z=1,3 do local f=baseFields and baseFields[z]; data._circBaseCell1[z]=finiteNumber(f and f[1],finiteNumber(baseSurface and baseSurface[z],ENV_TEMP)); data._circBaseCell2[z]=finiteNumber(f and f[2],data._circBaseCell1[z]); data._circBaseCell3[z]=finiteNumber(f and f[3],data._circBaseCell2[z]) end
        data.circumferential_contact_tread_cell1_temp_zone_c=data._circBaseCell1; data.circumferential_contact_tread_cell2_temp_zone_c=data._circBaseCell2; data.circumferential_contact_tread_cell3_temp_zone_c=data._circBaseCell3
        data.circumferential_contact_grip_cells_zone_c=baseFields; data.circumferential_contact_surface_temp_zone_c=baseSurface
        data.circumferential_contact_surface_temp_c=surfaceAvg; data.circumferential_contact_grip_depth_temp_c=gripAvg; data.circumferential_contact_grip_depth_delta_c=0
        data.circumferential_hotspot_contact_delta_c=0; data.circumferential_hotspot_peak_delta_c=0; data.circumferential_coldspot_contact_drop_c=0; data.circumferential_coldspot_peak_drop_c=0; data.circumferential_hot_energy_j=0; data.circumferential_cold_energy_j=0; data.circumferential_abs_thermal_energy_j=0
        data._circContactResult=data._circContactResult or {}; local result=data._circContactResult
        result.surfaceTempZone=baseSurface; result.localGripDepthTemp=gripAvg; result.localGripDepthDelta=0; result.localGripCellsByZone=baseFields
        return result
    end
    local zoneLayerDelta={{0,0,0,0},{0,0,0,0},{0,0,0,0}}; local zoneTemps={0,0,0}; local layerEnergy={0,0,0,0}
    local maxHotContactDelta,maxHotPeakDelta,maxColdContactDrop,maxColdPeakDrop=0,0,0,0; local positiveEnergy,negativeEnergyMagnitude,totalAbsEnergy=0,0,0
    for z=1,3 do zoneTemps[z]=finiteNumber(baseSurface and baseSurface[z],finiteNumber(data.temp and data.temp[z],ENV_TEMP)) end
    for _,raw in ipairs(features or {}) do
        local feature=cfg.ensureFeatureSchema(raw)
        for z=1,3 do
            local n,cellCaps
            if thermalCache and thermalCache.zoneGeometry and thermalCache.zoneGeometry[z] then
                n=thermalCache.zoneGeometry[z].activeCount
                cellCaps=thermalCache.zoneGeometry[z].capacityJPerK
            else
                n,_,_,_,_,cellCaps=cfg.zoneThermalGeometry(data,geom,z)
            end
            for l=1,cfg.localDepthCount do
                local _,_,span=cfg.getLayerCellRange(l,n)
                if span>0 then
                    local layer=feature.layers[l]; local capacity=cfg.layerCapacityFromCells(cellCaps,l,n); local w=clamp(finiteNumber(layer.halfWidthTurns,cfg.minHalfWidthTurns),cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns); local e=finiteNumber(layer.energyJ[z],0)
                    if math.abs(e)>0 then
                        local peak=e/math.max(capacity*w,1e-9); local localDelta=peak*cfg.contactKernel(state,feature,l); zoneLayerDelta[z][l]=zoneLayerDelta[z][l]+localDelta; layerEnergy[l]=layerEnergy[l]+e; totalAbsEnergy=totalAbsEnergy+math.abs(e)
                        if e>=0 then positiveEnergy=positiveEnergy+e else negativeEnergyMagnitude=negativeEnergyMagnitude-e end
                        if l==1 then maxHotContactDelta=math.max(maxHotContactDelta,localDelta); maxHotPeakDelta=math.max(maxHotPeakDelta,peak); maxColdContactDrop=math.max(maxColdContactDrop,-localDelta); maxColdPeakDrop=math.max(maxColdPeakDrop,-peak) end
                    end
                end
            end
        end
    end
    local localGripCellsByZone={{},{},{}}; local localGripTempByZone={ENV_TEMP,ENV_TEMP,ENV_TEMP}; local decay=math.max(finiteNumber(geom.gripDepthDecayM,M._tread1D.gripDepthDecayM),1e-6)
    local c1,c2,c3={0,0,0},{0,0,0},{0,0,0}
    for z=1,3 do
        zoneTemps[z]=zoneTemps[z]+zoneLayerDelta[z][1]; local field=baseFields and baseFields[z] or nil; local zg=thermalCache and thermalCache.zoneGeometry and thermalCache.zoneGeometry[z] or (geom.zoneCellGeometry and geom.zoneCellGeometry[z]); if type(zg)~="table" then local _,_,_,_,_,_,tmp=cfg.zoneThermalGeometry(data,geom,z); zg=tmp end
        local num,den=0,0
        for j=1,zg.activeCount do local d=0; for l=1,cfg.localDepthCount do local first,last,span=cfg.getLayerCellRange(l,zg.activeCount); if span>0 and j>=first and j<=last then d=zoneLayerDelta[z][l]; break end end; local t=finiteNumber(field and field[j],zoneTemps[z])+d; localGripCellsByZone[z][j]=t; local w=M._tread1D.getGripDepthWeightFromGeometry(zg,j,decay); num=num+t*w; den=den+w end
        localGripTempByZone[z]=num/math.max(den,1e-9); c1[z]=finiteNumber(localGripCellsByZone[z][1],zoneTemps[z]); c2[z]=finiteNumber(localGripCellsByZone[z][2],c1[z]); c3[z]=finiteNumber(localGripCellsByZone[z][3],c2[z])
    end
    local layerDelta={0,0,0,0}; for l=1,cfg.localDepthCount do layerDelta[l]=TempRingsToAvgTemp({zoneLayerDelta[1][l],zoneLayerDelta[2][l],zoneLayerDelta[3][l]},loadBias,contactWeights) end
    local localGrip=TempRingsToAvgTemp(localGripTempByZone,loadBias,contactWeights); local baseGrip=thermalCache and finiteNumber(thermalCache.gripDepthAvgTemp,data.grip_depth_avg_temp) or finiteNumber(data.grip_depth_avg_temp,TempRingsToAvgTemp(data.temp,loadBias,contactWeights)); local gripDelta=localGrip-baseGrip
    data.circumferential_contact_layer_delta_zone_c=zoneLayerDelta; data.circumferential_contact_layer_delta_c=layerDelta; data.circumferential_local_layer_energy_j=layerEnergy; data.circumferential_contact_tread_cell1_temp_zone_c=c1; data.circumferential_contact_tread_cell2_temp_zone_c=c2; data.circumferential_contact_tread_cell3_temp_zone_c=c3; data.circumferential_contact_grip_cells_zone_c=localGripCellsByZone
    data.circumferential_contact_surface_temp_zone_c=zoneTemps; data.circumferential_contact_surface_temp_c=TempRingsToAvgTemp(zoneTemps,loadBias,contactWeights); data.circumferential_contact_grip_depth_temp_zone_c=localGripTempByZone; data.circumferential_contact_grip_depth_temp_c=localGrip; data.circumferential_contact_grip_depth_delta_c=gripDelta
    data.circumferential_hotspot_contact_delta_c=maxHotContactDelta; data.circumferential_hotspot_peak_delta_c=maxHotPeakDelta; data.circumferential_coldspot_contact_drop_c=maxColdContactDrop; data.circumferential_coldspot_peak_drop_c=maxColdPeakDrop; data.circumferential_hot_energy_j=positiveEnergy; data.circumferential_cold_energy_j=negativeEnergyMagnitude; data.circumferential_abs_thermal_energy_j=totalAbsEnergy
    return {surfaceTempZone=zoneTemps,localGripDepthTemp=localGrip,localGripDepthDelta=gripDelta,localGripCellsByZone=localGripCellsByZone}
end

M._circumferential.remapAdaptiveZoneLayers = function(data, zone, oldGeom, newGeom, removedDepthM)
    local cfg=M._circumferential; local state=cfg.ensureState(data); local shift=math.max(finiteNumber(removedDepthM,0),0); local exported=0; local error=0
    local function bounds(g,l) local f,last,count=cfg.getLayerCellRange(l,g.activeCount); if count<=0 then return nil,nil end; return g.startM[f],g.endM[last] end
    for _,raw in ipairs(state.thermalFeatures or {}) do
        local feature=cfg.ensureFeatureSchema(raw); local newE={0,0,0,0}; local widthNum={0,0,0,0}; local widthDen={0,0,0,0}; local oldSum=0; local featureExported=0
        for l=1,cfg.localDepthCount do
            local oa,ob=bounds(oldGeom,l); local e=finiteNumber(feature.layers[l].energyJ[zone],0); oldSum=oldSum+e
            if oa and ob and ob>oa and math.abs(e)>0 then
                local retained=0
                for nl=1,cfg.localDepthCount do local na,nb=bounds(newGeom,nl); if na and nb then local overlap=math.max(math.min(ob,shift+nb)-math.max(oa,shift+na),0); if overlap>0 then local share=e*overlap/(ob-oa); newE[nl]=newE[nl]+share; retained=retained+share; widthNum[nl]=widthNum[nl]+math.abs(share)*finiteNumber(feature.layers[l].halfWidthTurns,cfg.minHalfWidthTurns); widthDen[nl]=widthDen[nl]+math.abs(share) end end end
                featureExported=featureExported+(e-retained)
            else featureExported=featureExported+e end
        end
        local newSum=0
        for l=1,cfg.localDepthCount do feature.layers[l].energyJ[zone]=newE[l]; if widthDen[l]>0 then feature.layers[l].halfWidthTurns=clamp(widthNum[l]/widthDen[l],cfg.minHalfWidthTurns,cfg.maxHalfWidthTurns) end; newSum=newSum+newE[l] end
        exported=exported+featureExported
        error=error+(oldSum-featureExported-newSum)
    end
    data.wear_exported_hotspot_energy_j=finiteNumber(data.wear_exported_hotspot_energy_j,0)+exported
    data.adaptive_hotspot_remap_error_j=finiteNumber(data.adaptive_hotspot_remap_error_j,0)+error
    return exported,error
end

M._circumferential.mergeWearFeature = function(state, phase, halfWidthTurns, zoneAverageDepthM)
    local cfg = M._circumferential
    local width = clamp(halfWidthTurns, cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    local totalMean = math.max(finiteNumber(zoneAverageDepthM[1], 0), 0)
        + math.max(finiteNumber(zoneAverageDepthM[2], 0), 0)
        + math.max(finiteNumber(zoneAverageDepthM[3], 0), 0)
    if totalMean <= 0 then return end
    local features = state.wearFeatures
    local best, bestDistance = nil, 1
    for _, feature in ipairs(features) do
        local distance = math.abs(cfg.signedPhaseDelta(phase, feature.phase))
        local threshold = math.max(cfg.minHalfWidthTurns * 2,
            (finiteNumber(feature.halfWidthTurns, cfg.minHalfWidthTurns) + width) * cfg.mergeDistanceScale)
        if distance <= threshold and distance < bestDistance then best, bestDistance = feature, distance end
    end
    if not best then
        best = {phase = cfg.wrap01(phase), halfWidthTurns = width, meanM = {0, 0, 0}}
        table.insert(features, best)
    else
        local existingMean = math.max(finiteNumber(best.meanM and best.meanM[1], 0), 0)
            + math.max(finiteNumber(best.meanM and best.meanM[2], 0), 0)
            + math.max(finiteNumber(best.meanM and best.meanM[3], 0), 0)
        local signedDelta = cfg.signedPhaseDelta(phase, best.phase)
        best.phase = cfg.wrap01(best.phase + signedDelta * (totalMean / math.max(existingMean + totalMean, 1e-12)))
        best.halfWidthTurns = clamp(math.max(finiteNumber(best.halfWidthTurns, width), width,
            math.abs(signedDelta) + 0.5 * width), cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
    end
    best.meanM = type(best.meanM) == "table" and best.meanM or {0, 0, 0}
    for z = 1, 3 do
        local meanIncrement = math.max(finiteNumber(zoneAverageDepthM[z], 0), 0)
        best.meanM[z] = math.max(finiteNumber(best.meanM[z], 0), 0) + meanIncrement
    end
    while #features > cfg.maxWearFeatures do
        local weakestIndex, weakest = 1, math.huge
        for i, feature in ipairs(features) do
            local m = math.max(finiteNumber(feature.meanM and feature.meanM[1], 0), 0)
                + math.max(finiteNumber(feature.meanM and feature.meanM[2], 0), 0)
                + math.max(finiteNumber(feature.meanM and feature.meanM[3], 0), 0)
            if m < weakest then weakestIndex, weakest = i, m end
        end
        table.remove(features, weakestIndex)
    end
end

M._circumferential.depositWear = function(data, zoneDepthM)
    local cfg = M._circumferential
    local state = cfg.ensureState(data)
    if not tyreWearEnabled or not cfg.enabled or state.localFraction <= 0 then return end
    state.wearDepositScratch=type(state.wearDepositScratch)=="table" and state.wearDepositScratch or {0,0,0}
    local localizedAverage = state.wearDepositScratch
    local any = false
    for z = 1, 3 do
        localizedAverage[z] = math.max(finiteNumber(zoneDepthM and zoneDepthM[z], 0), 0) * state.localFraction
        any = any or localizedAverage[z] > 0
    end
    if any then cfg.mergeWearFeature(state, state.depositPhase, state.depositHalfWidthTurns, localizedAverage) end
end

M._circumferential.refreshContactWear = function(data, nominalDepthM)
    local cfg = M._circumferential
    local state = cfg.ensureState(data)
    state.wearContactAnomalyScratch=type(state.wearContactAnomalyScratch)=="table" and state.wearContactAnomalyScratch or {0,0,0}
    state.wearContactEffectiveScratch=type(state.wearContactEffectiveScratch)=="table" and state.wearContactEffectiveScratch or {0,0,0}
    local anomaly = state.wearContactAnomalyScratch
    local effective = state.wearContactEffectiveScratch
    anomaly[1],anomaly[2],anomaly[3]=0,0,0
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local requestedReserve = math.max(finiteNumber(M._tread1D and M._tread1D.nonWearableReserveM, 0.00050), 0.00010)
    local reserve = clamp(requestedReserve, 0.00010, nominal * 0.35)
    for _, feature in ipairs(state.wearFeatures) do
        local w = clamp(finiteNumber(feature.halfWidthTurns, cfg.minHalfWidthTurns),
            cfg.minHalfWidthTurns, cfg.maxHalfWidthTurns)
        local k = cfg.kernel(state.phase, feature.phase, w)
        for z = 1, 3 do
            local meanLocalizedWear = math.max(finiteNumber(feature.meanM and feature.meanM[z], 0), 0)
            anomaly[z] = anomaly[z] + meanLocalizedWear * (k / math.max(w, 1e-6) - 1)
        end
    end
    for z = 1, 3 do
        local avgDepth = finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[z], nominalDepthM)
        effective[z] = clamp(avgDepth - anomaly[z], reserve, nominalDepthM)
    end
    data.circumferential_contact_wear_anomaly_m = anomaly
    data.circumferential_contact_remaining_depth_m = effective
    data.circumferential_wear_feature_count = #state.wearFeatures
end

-- ABSOLUTE / BASELINE GRIP UPLIFT.
-- This layer is intentionally separate from the brush slip-shape corrector and
-- from all thermal/wear penalties. It scales the tyre's BeamNG-native friction
-- level upward while preserving the tyre's own static/sliding curve shape.
-- The automatic profile is selected per wheel from the actual installed tyre.
-- These are deliberately mild defaults, not claimed research constants.
-- Exact tyre-part overrides may be added where a specific construction requires separate calibration.
-- PRESSURE-WHEEL STRUCTURAL BRUSH CALIBRATION.
--
-- BeamNG already physically flexes the pressure wheel. We therefore do NOT add a
-- second sidewall force model. This is only a supervisory calibration that changes
-- how rim-level kinematic slip maps into the research brush sliding fraction B.
-- The original research full-slide sigma values remain reference anchors. Actual
-- pressure-wheel sidewall aspect ratio, width and LIVE gauge pressure move that
-- anchor modestly; generated pressureWheel spring values add a weak bounded construction
-- cue when available. A shorter/stiffer/higher-pressure tyre reaches full brush sliding
-- at less rim slip; a taller/softer/lower-pressure tyre reaches it later.
--
-- Profile reference geometry is intentionally editable calibration data.
-- Standard is anchored near the Pegram 145/80 R13 geometry; the other profile
-- references are representative pressure-wheel shapes rather than claimed constants.
-- Research refs: [R1][R5][R6][R7].
M._pressureWheelBrush = {
    enabled = true,
    tyreReferencePressureOverrides = {},
    strength = 1.00,
    sidewallAspectExponent = 1.00,
    aspectGeometryModel = "hewson-relative-v2-nominal-metric-size",
    hewsonVerticalDeflectionByProfile = {
        standard = 0.15, sport = 0.15, race = 0.10,
        rally_asphalt = 0.10, rally_gravel = 0.15, drift = 0.15,
    },
    minAspectFactor = 0.50,
    maxAspectFactor = 1.80,
    livePressureExponent = 0.25,
    widthExponent = 0.10,
    jbeamStructureInfluence = 0.18,
    minJbeamStructureFactor = 0.75,
    maxJbeamStructureFactor = 1.30,
    minStiffnessFactor = 0.62,
    maxStiffnessFactor = 1.65,

    dynamicFialaEnabled = true,
    corneringStiffnessPeakLoadRatio = 3.0,
    minDynamicLoadRatio = 0.20,
    maxDynamicLoadRatio = 3.00,
    dynamicLoadFilterTauS = 0.045,
    minCriticalAngleDeg = 3.0,
    maxCriticalAngleDeg = 24.0,
    profileTypeStiffness = {
        standard = 1.00,
        sport = 1.00,
        race = 1.00,
        rally_asphalt = 1.00,
        rally_gravel = 0.88,
        drift = 1.00,
    },
    referenceAspect = {
        standard = 0.80,
        sport = 0.45,
        race = 0.30,
        rally_asphalt = 0.43,
        rally_gravel = 0.60,
        drift = 0.40,
    },
    referenceWidthM = {
        standard = 0.145,
        sport = 0.235,
        race = 0.285,
        rally_asphalt = 0.226,
        rally_gravel = 0.225,
        drift = 0.265,
    },
    referencePressurePsi = {
        standard = 30.0,
        sport = 32.0,
        race = 28.0,
        rally_asphalt = 31.5,
        rally_gravel = 32.5,
        drift = 30.0,
    },
}

-- DEPTH-OWNED WEAR -> C_alpha COMPLIANCE MODEL.
-- Do NOT treat tread loss as a linear magic stiffness percentage. Tread-block
-- shear compliance and carcass compliance act approximately in series, so as
-- block height h falls the tread contribution shrinks and whole-tyre C_alpha
-- asymptotically becomes carcass-dominated:
--
-- C_alpha(worn) / C_alpha(new) = 1 / ((1-q) + q * h/h0)
--
-- q is the fresh tyre's tread share of total lateral compliance. For grooved
-- families h/h0 is ACTIVE GROOVE/BLOCK HEIGHT, not total rubber thickness; once
-- grooves are gone the block-squirm gain is already saturated. Slick/Drift,
-- which have no KTS groove geometry, use remaining solid wearable thickness.
--
-- [WS-R1][MEASURED/LITERATURE] Michelin XZA data summarized by NHVR:
-- 50% tread -> +19% C_alpha, 33% tread -> +26%. Solving the series-compliance
-- equation gives q ~= 0.31 from both points independently.
-- https://www.nhvr.gov.au/files/201903-1018-review-of-tyre-management-practice-in-pbs-discussion-paper.pdf
-- [WS-R2][MEASURED, HIGH-PERFORMANCE SUMMER] Goodyear Eagle F1 Flat-Trac:
-- full / 60% / 30% tread-depth tests; lower tread depth raises C_alpha and the
-- effect saturates as carcass stiffness becomes dominant.
-- https://doi.org/10.4271/2015-01-1521
-- [WS-R3][TEXTBOOK/MECHANICS] smaller tread/slit depth raises cornering stiffness.
-- https://www.sciencedirect.com/topics/engineering/cornering-stiffness
--
-- Class q values below are provenance-labelled calibration. Standard uses the
-- direct Michelin fit. Sport is a small UHP interpolation toward the stronger
-- Goodyear trend. Semi-Slick is deliberately lower because its fresh blocks are
-- already shallow/stiff. Existing Rally/Slick/Drift maxima are preserved by
-- converting their old max gains to equivalent q = gain/(1+gain).
M._wearStructuralStiffness = {
    complianceShareByClass = {
        standard = 0.31,      -- [WS-R1] direct literature fit (~+45% at zero block height)
        sport = 0.33,         -- [WS-R2][KTS interpolation] UHP/high-performance road (~+49% max)
        semi_slick = 0.153,   -- [KTS engineering] preserves prior ~+18% max, shallower fresh blocks
        race = 0.0741,        -- [KTS engineering] preserves prior ~+8% max for solid slick tread
        rally_asphalt = 0.1071, -- [KTS engineering] preserves prior ~+12% max
        rally_gravel = 0.2308,  -- [KTS engineering] preserves prior ~+30% max
        drift = 0.1071,       -- [KTS engineering] preserves prior ~+12% max
    },
}

M._baselineGripUplift = {
    enabled = true,
    maxMultiplier = 1.35,
    profileMultipliers = {
        standard = 1.00,
        sport = 1.01,
        semi_slick = 1.02,
        race = 1.00,
        rally_asphalt = 1.00,
        rally_gravel = 1.00,
        drift = 1.00,
    },
    tyreOverrides = {},
}

M._repeatedTestThermalCap = {
    enabled = false,
    bulkTreadMaxWorkingFactor = 1.20,
    applyCaps = function() end,
}

--
M._slipPlateau = {
    enabled = true,
    surfaceHeatEnabled = true,

    coolFullSlideRatioByProfile = {
        standard = 0.88,
        sport = 0.90,
        race = 0.86,
        rally_asphalt = 0.89,
        rally_gravel = 0.84,
        drift = 0.00,
    },

    hotFullSlideRatioByProfile = {
        standard = 0.00,
        sport = 0.00,
        race = 0.00,
        rally_asphalt = 0.00,
        rally_gravel = 0.00,
        drift = 0.00,
    },

    profileThermalCurveSlideByProfile = {
        standard = true,
        sport = true,
        race = true,
        rally_asphalt = true,
        rally_gravel = true,
        drift = true,
    },

    coolTyreOverrides = {},
    hotTyreOverrides = {},

    surfaceGripFadeStartAboveWorkingC = {
        standard = 20.0,
        sport = 15.0,
        race = 12.0,
        rally_asphalt = 10.0,
        rally_gravel = 12.0,
        drift = 15.0,
    },
    surfaceGripSaturationAboveWorkingC = {
        standard = 130.0,
        sport = 130.0,
        race = 105.0,
        rally_asphalt = 105.0,
        rally_gravel = 120.0,
        drift = 115.0,
    },
    surfaceGripResponseExponentByProfile = {
        standard = 0.55,
        sport = 0.55,
        race = 0.60,
        rally_asphalt = 0.58,
        rally_gravel = 0.62,
        drift = 0.65,
    },

    shortTermSurfaceOverloadEnabled = true,
    shortTermRiseTauS = 0.16,
    shortTermReleaseTauS = 0.30,
    shortTermMaxOverloadC = 180.0,
    shortTermOnsetAboveGripDepthC = {
        standard = 12.0,
        sport = 15.0,
        race = 18.0,
        rally_asphalt = 15.0,
        rally_gravel = 18.0,
        drift = 22.0,
    },
    shortTermSaturationAboveGripDepthC = {
        standard = 90.0,
        sport = 105.0,
        race = 115.0,
        rally_asphalt = 100.0,
        rally_gravel = 125.0,
        drift = 140.0,
    },
    shortTermMinGripMultiplierByProfile = {
        standard = 0.78,
        sport = 0.80,
        race = 0.82,
        rally_asphalt = 0.80,
        rally_gravel = 0.83,
        drift = 0.90,
    },
    shortTermResponseExponentByProfile = {
        standard = 0.75,
        sport = 0.75,
        race = 0.80,
        rally_asphalt = 0.78,
        rally_gravel = 0.80,
        drift = 0.85,
    },
}

local REWIND_SPINUP_TARGET_RATIO = 0.80
local REWIND_SPINUP_MIN_SPEED_KMH = 1.0
local REWIND_SPINUP_MAX_FREEZE_SECONDS = 0.60
local REWIND_SPINUP_TRACTION_EFFICIENCY = 0.70
local REWIND_SPINUP_MIN_LOAD_N = 100
local REWIND_SPINUP_RELEASE_ARM_RATIO = 0.45
local REWIND_SPINUP_MIN_HARD_HOLD_SECONDS = 0.015
local REWIND_SPINUP_MAX_TIMER_STEP_SECONDS = 0.020
local REWIND_SPINUP_PENDING_MAX_SECONDS = 1.000
local REWIND_SPINUP_PENDING_LOG_SECONDS = 0.100

local tyreGripTable = {}
local wheelFlashGripState = {}
local RT = {
    lockedPatchFlashGripEnabled = true,
    brakeDuctSettings = { -1, -1 },
    baseBrakeCoolings = {},
    wheelTyreProfiles = {},
    tyreProfileDetectionRevision = 0,
    tyreProfileDetectionSignature = "",
    tyreProfileRetryTimer = 0,
    tyreProfileRetryRemaining = 0,
    tyreProfileFallbackCount = 0,
    AUTO_PROFILE_RETRY_INTERVAL = 0.10,
    AUTO_PROFILE_RETRY_DURATION = 4.0,
    arcadeHandlingEnabled = false,
}

M._arcadeHandling = {
    thermalPenaltySeverity = 0.60,
    thermalStiffnessSeverity = 0.60,
    physicalStiffnessSeverity = 0.60,
    physicalWorkingTempC = 60.0,
    physicalWorkingBlendSpanC = 20.0,
}

local tyreData = {}
local wheelCache = {}

M._thermalPause = {
    active = false,
    wearBeforePause = false,
    restoreRequested = false,
    restoreRevision = 0
}

M._gripRefresh = {
    enabled = true,
    minimumHz = 60,
    intervalS = 1 / 60,
    maxTransitionS = 1 / 30,
    physicsAccumulator = 0,
    physicsSeen = false,
    lastGfxDt = 1 / 60,
    targets = {},
    applied = {},
    transitionStart = {},
    transitionAge = {},
    transitionDuration = {},
}

M._gripRefresh.applyWheel = function(wheelID, grip)
    local id = tonumber(wheelID)
    if id == nil then return false end
    local wheel = obj:getWheel(id)
    if not wheel then return false end
    local safeGrip = clamp(tonumber(grip) or 1, 0.02, 2.0)
    wheel:setFrictionThermalSensitivity(
        -300, 1e7, 1e-10, 1e-10, 10,
        safeGrip, safeGrip, safeGrip
    )
    M._gripRefresh.applied[id] = safeGrip
    return true
end

M._gripRefresh.forceWheel = function(wheelID, grip)
    local id = tonumber(wheelID)
    if id == nil then return false end
    local safeGrip = clamp(tonumber(grip) or 1, 0.02, 2.0)
    M._gripRefresh.targets[id] = safeGrip
    M._gripRefresh.transitionStart[id] = safeGrip
    M._gripRefresh.transitionAge[id] = 0
    M._gripRefresh.transitionDuration[id] = 0
    return M._gripRefresh.applyWheel(id, safeGrip)
end

M._gripRefresh.setTarget = function(wheelID, grip, gfxDt)
    local id = tonumber(wheelID)
    if id == nil then return false end
    local safeGrip = clamp(tonumber(grip) or 1, 0.02, 2.0)
    local sourceDt = clamp(tonumber(gfxDt) or M._gripRefresh.lastGfxDt or M._gripRefresh.intervalS,
        0.001, 0.10)
    M._gripRefresh.lastGfxDt = sourceDt
    M._gripRefresh.targets[id] = safeGrip

    if not M._gripRefresh.physicsSeen or sourceDt <= M._gripRefresh.intervalS * 1.05 then
        return M._gripRefresh.forceWheel(id, safeGrip)
    end

    local current = M._gripRefresh.applied[id]
    if current == nil then
        return M._gripRefresh.forceWheel(id, safeGrip)
    end
    M._gripRefresh.transitionStart[id] = current
    M._gripRefresh.transitionAge[id] = 0
    M._gripRefresh.transitionDuration[id] = clamp(sourceDt,
        M._gripRefresh.intervalS, M._gripRefresh.maxTransitionS)
    return true
end

M._gripRefresh.step = function(stepDt)
    local dtStep = math.max(tonumber(stepDt) or M._gripRefresh.intervalS, 0)
    for wheelID, target in pairs(M._gripRefresh.targets) do
        local duration = math.max(tonumber(M._gripRefresh.transitionDuration[wheelID]) or 0, 0)
        local nextGrip = target
        if duration > 0 then
            local age = math.min((tonumber(M._gripRefresh.transitionAge[wheelID]) or 0) + dtStep, duration)
            M._gripRefresh.transitionAge[wheelID] = age
            local u = clamp(age / duration, 0, 1)
            local blend = u * u * (3 - 2 * u)
            local startGrip = tonumber(M._gripRefresh.transitionStart[wheelID]) or target
            nextGrip = startGrip + (target - startGrip) * blend
            if age >= duration then
                nextGrip = target
                M._gripRefresh.transitionDuration[wheelID] = 0
            end
        end
        local previous = tonumber(M._gripRefresh.applied[wheelID])
        if previous == nil or math.abs(nextGrip - previous) > 0.00005 then
            M._gripRefresh.applyWheel(wheelID, nextGrip)
        end
    end
end

M._gripRefresh.updatePhysics = function(dt)
    if not M._gripRefresh.enabled then return end
    M._gripRefresh.physicsSeen = true
    local safeDt = clamp(tonumber(dt) or 0, 0, 0.05)
    M._gripRefresh.physicsAccumulator = M._gripRefresh.physicsAccumulator + safeDt
    local interval = M._gripRefresh.intervalS
    local iterations = 0
    while M._gripRefresh.physicsAccumulator >= interval and iterations < 4 do
        M._gripRefresh.physicsAccumulator = M._gripRefresh.physicsAccumulator - interval
        M._gripRefresh.step(interval)
        iterations = iterations + 1
    end
    if M._gripRefresh.physicsAccumulator >= interval then
        M._gripRefresh.physicsAccumulator = M._gripRefresh.physicsAccumulator % interval
        M._gripRefresh.step(interval)
    end
end

M._gripRefresh.reset = function()
    M._gripRefresh.physicsAccumulator = 0
    M._gripRefresh.targets = {}
    M._gripRefresh.applied = {}
    M._gripRefresh.transitionStart = {}
    M._gripRefresh.transitionAge = {}
    M._gripRefresh.transitionDuration = {}
end

M._rallyDirt.updatePhysicsRoute = function(dt)
    if M._rallyDirt.enabled == false then return end
    for wheelID, wd in pairs(wheels and wheels.wheelRotators or {}) do
        local data = tyreData[wheelID]
        if type(data) == "table" and M._rallyDirt.isRallyProfile(data.tyre_profile) then
            local signature = tostring(tonumber(wd.contactMaterialID1) or -1)
                .. ":" .. tostring(tonumber(wd.contactMaterialID2) or -1)
            if signature ~= M._rallyDirt.wheelMaterialSignature[wheelID] then
                M._rallyDirt.wheelMaterialSignature[wheelID] = signature
                local previous = M._rallyDirt.wheelRouteClass[wheelID]
                    or data.rally_surface_class or "road"
                local surfaceClass = M._rallyDirt.classifyWheelNow(wheelID, previous)
                M._rallyDirt.wheelRouteClass[wheelID] = surfaceClass
                if surfaceClass ~= previous then
                    M._rallyDirt.physicsRouteChanges = M._rallyDirt.physicsRouteChanges + 1
                    data.rally_surface_class = surfaceClass
                    data.rally_surface_label = M._rallyDirt.surfaces[surfaceClass]
                        and M._rallyDirt.surfaces[surfaceClass].label or "Hard road"
                    data.rally_road_model_active = surfaceClass == "road"
                    data.rally_dirt_model_active = M._rallyDirt.surfaces[surfaceClass] ~= nil
                    if data.rally_dirt_model_active then
                        local macro = M._rallyDirt.getMacroGrip(wheelID, surfaceClass)
                        local fast = M._rallyDirt.getFastGrip(wheelFlashGripState[wheelID], surfaceClass)
                        local target = M._wearResearch.clamp(macro * fast, 0.02, 1.0)
                        data.rally_dirt_fast_multiplier = fast
                        data.rally_overlay_multiplier = target
                        data.rally_surface_router_source = "physics-first-tick-dirt"
                        tyreGripTable[wheelID] = target
                        M._gripRefresh.forceWheel(wheelID, target)
                    else
                        data.rally_surface_router_source = "physics-native-road-bridge"
                        data.rally_overlay_multiplier = 1.0
                        tyreGripTable[wheelID] = 1.0
                        M._gripRefresh.forceWheel(wheelID, 1.0)
                    end
                end
            end
        end
    end
end

M._rallyDirt.resetRoutes = function()
    M._rallyDirt.wheelRouteClass = {}
    M._rallyDirt.wheelMaterialSignature = {}
    M._rallyDirt.physicsRouteChanges = 0
end

--
--
M._camberSurface = {
    rayCount = 8,
    refineSteps = 2,
    extraRangeM = 0.12,
    sideSampleRatio = 0.35,
    sideSampleMinM = 0.025,
    sideSampleMaxM = 0.100,
    minContactLoadN = 5,
    normalHoldS = 0.20,
    sidewallContactRejectCamberDeg = 35,
    cache = {}
}

M._camberSurface.safeCastRayStatic = function(origin, direction, maxDistance)
    if not origin or not direction or not maxDistance or maxDistance <= 0 then return nil end

    local dir = direction:normalized()
    if dir:length() < 0.5 then return nil end

    local ok, hitDistance
    if obj and obj.castRayStatic then
        ok, hitDistance = pcall(obj.castRayStatic, obj, origin, dir, maxDistance)
    elseif castRayStatic then
        ok, hitDistance = pcall(castRayStatic, origin, dir, maxDistance)
    end

    if not ok or type(hitDistance) ~= "number" then return nil end
    if hitDistance < 0 or hitDistance >= maxDistance * 0.999 then return nil end
    return hitDistance
end

M._camberSurface.estimateContactSurfaceNormal = function(wheelID, wd, wheelCenter, axleAxis, wheelForward, wheelUp, dt)
    local cfg = M._camberSurface
    local cache = cfg.cache[wheelID]
    local load = math.max(tonumber(wd.downForceRaw) or 0, tonumber(wd.downForce) or 0, 0)
    local contactMaterial = tonumber(wd.contactMaterialID1)
    local hasWheelContact = load >= cfg.minContactLoadN or (contactMaterial and contactMaterial >= 0)

    if not hasWheelContact then
        if cache and (cache.age or 0) < cfg.normalHoldS then
            cache.age = (cache.age or 0) + math.max(dt or 0, 0)
            return cache.normal, "cached-contact"
        end
        return nil, "airborne"
    end

    local axle = axleAxis:normalized()
    local forward = wheelForward:normalized()
    local up = wheelUp:normalized()
    if axle:length() < 0.5 or forward:length() < 0.5 or up:length() < 0.5 then
        return nil, "bad-wheel-basis"
    end

    local radius = math.max(tonumber(wd.radius) or 0.3, 0.05)
    local maxDistance = radius + cfg.extraRangeM
    local coarseStep = math.pi * 2 / cfg.rayCount

    local function radialDir(theta)
        return (up * math.cos(theta) + forward * math.sin(theta)):normalized()
    end

    local bestTheta, bestDistance = nil, math.huge
    for sample = 0, cfg.rayCount - 1 do
        local theta = sample * coarseStep
        local d = cfg.safeCastRayStatic(wheelCenter, radialDir(theta), maxDistance)
        if d and d < bestDistance then
            bestDistance = d
            bestTheta = theta
        end
    end

    if not bestTheta then
        if cache and (cache.age or 0) < cfg.normalHoldS then
            cache.age = (cache.age or 0) + math.max(dt or 0, 0)
            return cache.normal, "cached-miss"
        end
        return nil, "no-static-hit"
    end

    local refineStep = coarseStep * 0.5
    for _ = 1, cfg.refineSteps do
        local leftTheta = bestTheta - refineStep
        local rightTheta = bestTheta + refineStep
        local leftDistance = cfg.safeCastRayStatic(wheelCenter, radialDir(leftTheta), maxDistance)
        local rightDistance = cfg.safeCastRayStatic(wheelCenter, radialDir(rightTheta), maxDistance)
        if leftDistance and leftDistance < bestDistance then
            bestDistance = leftDistance
            bestTheta = leftTheta
        end
        if rightDistance and rightDistance < bestDistance then
            bestDistance = rightDistance
            bestTheta = rightTheta
        end
        refineStep = refineStep * 0.5
    end

    local towardSurface = radialDir(bestTheta)

    local tyreWidth = math.max(tonumber(wd.tireWidth) or tonumber(wd.width) or 0.20, 0.05)
    local sideOffset = clamp(tyreWidth * cfg.sideSampleRatio, cfg.sideSampleMinM, cfg.sideSampleMaxM)

    local plusDistance = cfg.safeCastRayStatic(wheelCenter + axle * sideOffset, towardSurface, maxDistance)
    local minusDistance = cfg.safeCastRayStatic(wheelCenter - axle * sideOffset, towardSurface, maxDistance)
    local distanceSlope = 0
    local source = "surface-ray-radial"

    if plusDistance and minusDistance then
        distanceSlope = (plusDistance - minusDistance) / (2 * sideOffset)
        source = "surface-ray-3point"
    elseif plusDistance then
        distanceSlope = (plusDistance - bestDistance) / sideOffset
        source = "surface-ray-plus"
    elseif minusDistance then
        distanceSlope = (bestDistance - minusDistance) / sideOffset
        source = "surface-ray-minus"
    end

    distanceSlope = clamp(distanceSlope, -3.7320508075689, 3.7320508075689)
    local surfaceNormal = (towardSurface * -1 + axle * distanceSlope):normalized()
    if surfaceNormal:length() < 0.5 then return nil, "bad-normal" end

    local candidateDotAxle = math.max(0, math.min(1, math.abs(axle:dot(surfaceNormal))))
    local candidateCamberDeg = math.deg(math.asin(candidateDotAxle))
    if candidateCamberDeg > (tonumber(cfg.sidewallContactRejectCamberDeg) or 35) then
        if cache and cache.normal and (cache.age or 0) < cfg.normalHoldS then
            cache.age = (cache.age or 0) + math.max(dt or 0, 0)
            return cache.normal, "cached-sidewall-reject"
        end
        return nil, "sidewall-contact-reject"
    end

    cfg.cache[wheelID] = { normal = surfaceNormal, age = 0 }
    return surfaceNormal, source
end

--
--
M._adaCamberBridge = {
    schema = 1,
    api = 1,
    provider = "luukstyrethermalsandwear",
    version = "13.6.2",
    available = true,
    paused = false,
    revision = 0,
    byName = {},
    byId = {}
}

M._adaCamberBridge.beginFrame = function(dt)
    local bridge = M._adaCamberBridge
    bridge.available = true
    bridge.paused = M._thermalPause.active == true
    bridge.revision = (tonumber(bridge.revision) or 0) + 1
    bridge.lastDt = tonumber(dt) or 0
end

M._adaCamberBridge.publishWheel = function(wheelID, wd, cache)
    local bridge = M._adaCamberBridge
    local keyName = tostring((wd and wd.name) or (cache and cache.name) or wheelID or "")
    local keyId = tostring(wheelID or "")
    local sample = bridge.byName[keyName] or bridge.byId[keyId] or {}

    sample.name = keyName
    sample.wheelID = wheelID
    sample.camberDeg = tonumber(cache and cache.camber) or 0
    sample.source = tostring((cache and cache.camberSurfaceSource) or "unavailable")
    sample.valid = (bridge.paused ~= true and cache and cache.camberSurfaceValid == true) and true or false
    sample.loadN = math.max(tonumber(wd and wd.downForceRaw) or 0, tonumber(wd and wd.downForce) or 0, 0)
    sample.contactMaterialID1 = tonumber(wd and wd.contactMaterialID1)
    sample.revision = bridge.revision

    bridge.byName[keyName] = sample
    bridge.byId[keyId] = sample
end

M._adaCamberBridge.reset = function()
    local bridge = M._adaCamberBridge
    bridge.available = true
    bridge.paused = M._thermalPause.active == true
    bridge.revision = (tonumber(bridge.revision) or 0) + 1
    bridge.byName = {}
    bridge.byId = {}
end

M.adaGetSurfaceCamberBridge = function()
    return M._adaCamberBridge
end

local preheatRevision = 0
local wheelPreheatRevision = {}
local pendingPreheatTargets = {}
local pendingPreheatModes = {}

local vehicleMass
local activeWheelCount = 4

local wheelWaterNodeCache = {}
local vehicleWaterNodeCache = {}
local wheelWaterHold = {}
local vehicleWaterHold = 0
local waterDetectionMode = "unavailable"
local waterApiAvailable = nil

local totalTimeMod60 = 0
local wheelPressureReferenceCache = {}
local pressureSetterAvailable = nil
local ambientPressurePa = STANDARD_ATMOSPHERIC_PRESSURE_PA
local tyreWearEnabled = false

local rewindSpinupFreeze = {}
local pendingRewindSpinupContext = nil
local activeRewindSpinupRequestId = -1
local latestRewindRestoreRequestId = -1

local degubStepFinished = true

local THERMAL_PRESETS = {
    general = {
        id = "general", label = "General / drift-focused",
        values = {
            working_temp_c = -1, hot_grip_loss_factor = 1.0,
            cornering_heat_rate = 1.0, slip_heat_rate = 1.0,
            ambient_skin_cooling_rate = 1.0, speed_skin_cooling_rate = 1.0,
            brake_to_core_rate = 1.0,
            wear_rate = 1.0, ground_cooling_strength_percent = 1.0,
            grass_ground_cooling_strength_percent = 10.0, grass_slip_heat_rate = 0.1666666666666667,
            water_cooling_multiplier = 30.0, contact_patch_log_gain = 100000,
            contact_patch_deadzone_percent = 0.2, ground_cooling_max_factor = 1.35,
        }
    },
    race = {
        id = "race", label = "GT3 slick",
        values = {
            working_temp_c = -1, hot_grip_loss_factor = 1.0,
            cornering_heat_rate = 1.0, slip_heat_rate = 1.0,
            ambient_skin_cooling_rate = 1.0, speed_skin_cooling_rate = 1.0,
            brake_to_core_rate = 1.0,
            wear_rate = 1.0, ground_cooling_strength_percent = 1.0,
            grass_ground_cooling_strength_percent = 5.0, grass_slip_heat_rate = 0.1666666666666667,
            water_cooling_multiplier = 30.0, contact_patch_log_gain = 100000,
            contact_patch_deadzone_percent = 0.2, ground_cooling_max_factor = 1.35,
        }
    },
}
local ACTIVE_THERMAL_PRESET = "general"

local function applyThermalPresetValues(presetId)
    local preset = THERMAL_PRESETS[presetId] or THERMAL_PRESETS.general
    local v = preset.values
    WORKING_TEMP = v.working_temp_c
    HOT_GRIP_LOSS_FACTOR = v.hot_grip_loss_factor
    TEMP_WORK_GAIN_RATE = v.cornering_heat_rate
    TEMP_SLIP_GAIN_RATE = v.slip_heat_rate
    TEMP_COOL_RATE = v.ambient_skin_cooling_rate
    TEMP_COOL_VEL_RATE = v.speed_skin_cooling_rate
    TEMP_GAIN_RATE_CORE = v.brake_to_core_rate
    WEAR_RATE = v.wear_rate
    GROUND_COOLING_SCALE = v.ground_cooling_strength_percent
    GRASS_GROUND_COOLING_SCALE = v.grass_ground_cooling_strength_percent
    GRASS_SLIP_HEAT_RATE = v.grass_slip_heat_rate
    WATER_COOLING_MULTIPLIER = v.water_cooling_multiplier
    M._physicalThermal.contactPatchModel.logGain = v.contact_patch_log_gain
    M._physicalThermal.contactPatchModel.deadzoneRatio = v.contact_patch_deadzone_percent / 100
    M._physicalThermal.contactPatchModel.groundCoolingMaxFactor = v.ground_cooling_max_factor
    ACTIVE_THERMAL_PRESET = preset.id
    return ACTIVE_THERMAL_PRESET
end

local function desiredThermalPresetId()
    if MANUAL_TYRE_PROFILE == "race" then return "race" end
    if MANUAL_TYRE_PROFILE ~= "auto" then return "general" end

    local wheelCount = 0
    for _, detected in pairs(RT.wheelTyreProfiles or {}) do
        wheelCount = wheelCount + 1
        if not detected.profile or detected.profile.id ~= "race" then
            return "general"
        end
    end
    return wheelCount > 0 and "race" or "general"
end

local function refreshThermalPreset(force)
    local desired = desiredThermalPresetId()
    if force or desired ~= ACTIVE_THERMAL_PRESET then
        applyThermalPresetValues(desired)
        return true
    end
    return false
end

M._arcadeHandling.applyThermalPenalty = function(value)
    value = clamp(finiteNumber(value, 1.0), 0.01, 2.0)
    if RT.arcadeHandlingEnabled ~= true or value >= 1.0 then return value end
    local severity = clamp(finiteNumber(M._arcadeHandling.thermalPenaltySeverity, 0.60), 0.0, 1.0)
    return clamp(1.0 - (1.0 - value) * severity, value, 1.0)
end

M._arcadeHandling.applyThermalStiffness = function(value)
    value = finiteNumber(value, 1.0)
    if RT.arcadeHandlingEnabled ~= true then return value end
    local severity = clamp(finiteNumber(M._arcadeHandling.thermalStiffnessSeverity, 0.60), 0.0, 1.0)
    return 1.0 + (value - 1.0) * severity
end

M._arcadeHandling.getPhysicalStiffnessAuthority = function(tempC)
    if RT.arcadeHandlingEnabled ~= true then return 1.0 end
    local base = clamp(finiteNumber(M._arcadeHandling.physicalStiffnessSeverity, 0.60), 0.0, 1.0)
    local working = finiteNumber(M._arcadeHandling.physicalWorkingTempC, 60.0)
    local span = math.max(finiteNumber(M._arcadeHandling.physicalWorkingBlendSpanC, 20.0), 1.0)
    local distance = math.abs(finiteNumber(tempC, working) - working)
    if distance >= span then return base end
    local u = clamp(1.0 - distance / span, 0.0, 1.0)
    local smooth = u * u * (3.0 - 2.0 * u)
    return base + (1.0 - base) * smooth
end

M._beamStructureTuner = {
    multipliers = {
        sideSpring = 1.0,
        sideDamp = 1.0,
        sideExpansionSpring = 1.0,
        sideExpansionDamp = 1.0,
        treadSpring = 1.0,
        treadDamp = 1.0,
        sidePrecompression = 1.0,
        treadPrecompression = 1.0,
        reinfPrecompression = 1.0,
        reinfSpring = 1.0,
        reinfDamp = 1.0,
    },
    cache = {},
    wheelTreadSpringScale = {},
    wheelTreadSpringOwned = {},
    wheelSideSpringScale = {},
    wheelReinfSpringScale = {},
    wheelTreadDampScale = {},
    wheelTreadDampOwned = {},
    wheelTreadPrecompressionScale = {},
    wheelTreadPrecompressionOwned = {},
    geometryBaseline = nil,
    geometryLast = nil,
    geometryHudIntervalS = 0.20,
    geometryHudAccumulatorS = 0,
    cacheReady = false,
    pendingApply = true,
    revision = 0,
    stats = {
        cached = 0, applied = 0, failed = 0, skippedDeflated = 0,
        side = 0, tread = 0, reinf = 0,
        refApplied = 0, refFailed = 0,
        wheelCount = 0, endpointResolved = 0, endpointMissing = 0,
        lastError = "waiting-for-wheel-beams"
    },
}

M._beamStructureTuner.resetCache = function()
    local self = M._beamStructureTuner
    self.cache = {}
    self.wheelTreadSpringScale = {}
    self.wheelTreadSpringOwned = {}
    self.wheelSideSpringScale = {}
    self.wheelReinfSpringScale = {}
    self.wheelTreadDampScale = {}
    self.wheelTreadDampOwned = {}
    self.wheelTreadPrecompressionScale = {}
    self.wheelTreadPrecompressionOwned = {}
    self.geometryBaseline = nil
    self.geometryLast = nil
    self.geometryHudAccumulatorS = 0
    self.cacheReady = false
    self.pendingApply = true
    self.stats.cached = 0
    self.stats.applied = 0
    self.stats.failed = 0
    self.stats.side = 0
    self.stats.tread = 0
    self.stats.reinf = 0
    self.stats.wheelCount = 0
    self.stats.endpointResolved = 0
    self.stats.endpointMissing = 0
    self.stats.lastError = "cache-reset"
end

M._beamStructureTuner.rebuildCache = function()
    local self = M._beamStructureTuner
    self.cache = {}
    self.stats.endpointResolved = 0
    self.stats.endpointMissing = 0
    local seen = {}
    local wheelDefs = v and v.data and v.data.wheels or nil
    if type(wheelDefs) ~= "table" then
        self.cacheReady = false
        self.stats.lastError = "v.data.wheels-unavailable"
        return false
    end

    local function safeNumber(value)
        local valueType = type(value)
        local n = nil
        if valueType == "number" then
            n = value
        elseif valueType == "string" then
            local ok, converted = pcall(tonumber, value)
            if ok then n = converted end
        end
        if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
        return nil
    end

    local function firstNumber(...)
        for i = 1, select('#', ...) do
            local n = safeNumber(select(i, ...))
            if n ~= nil then return n end
        end
        return nil
    end

    local groupCounts = {side = 0, tread = 0, reinf = 0}
    local wheelSeen = {}

    local compiledNodeCidByName = {}
    local nodesData = v and v.data and v.data.nodes or nil
    if type(nodesData) == "table" then
        for nodeKey, node in pairs(nodesData) do
            if type(node) == "table" then
                local cid = safeNumber(node.cid) or safeNumber(nodeKey)
                if cid ~= nil then
                    compiledNodeCidByName[tostring(cid)] = cid
                    if type(node.name) == "string" and node.name ~= "" then
                        compiledNodeCidByName[node.name] = cid
                    end
                    if type(nodeKey) == "string" and safeNumber(nodeKey) == nil then
                        compiledNodeCidByName[nodeKey] = cid
                    end
                end
            end
        end
    end

    local function resolveNodeCid(value)
        local numeric = safeNumber(value)
        if numeric ~= nil then return numeric end
        if type(value) == "string" then return compiledNodeCidByName[value] end
        return nil
    end

    local compiledBeamByCid = {}
    local beamsData = v and v.data and v.data.beams or nil
    if type(beamsData) == "table" then
        for _, b in pairs(beamsData) do
            if type(b) == "table" then
                local cid = safeNumber(b.cid)
                if cid ~= nil then compiledBeamByCid[tostring(cid)] = b end
            end
        end
    end

    local function beamDataByCid(cid)
        if cid == nil then return nil end
        local mapped = compiledBeamByCid[tostring(cid)]
        if type(mapped) == "table" then return mapped end
        if type(beamsData) == "table" then
            local direct = beamsData[cid]
            if type(direct) == "table" then return direct end
            local plusOne = beamsData[cid + 1]
            if type(plusOne) == "table" and safeNumber(plusOne.cid) == cid then return plusOne end
        end
        return nil
    end

    local function addGroup(wheelKey, wheelDef, groupName, beamList)
        if type(beamList) ~= "table" then return end
        local wheelID = safeNumber(wheelDef and wheelDef.wheelID)
        if wheelID == nil then wheelID = safeNumber(wheelKey) or wheelKey end
        for _, beam in pairs(beamList) do
            local beamTable = type(beam) == "table" and beam or nil
            local cid = safeNumber(beamTable and beamTable.cid or beam)
            if cid and not seen[cid] then
                local globalBeam = beamDataByCid(cid)
                local entry = {
                    cid = cid,
                    wheelID = wheelID,
                    wheelName = tostring(wheelDef and wheelDef.name or wheelID or "?"),
                    group = groupName,
                    spring = firstNumber(
                        beamTable and beamTable.beamSpring,
                        beamTable and beamTable.spring,
                        globalBeam and globalBeam.beamSpring,
                        globalBeam and globalBeam.spring),
                    damp = firstNumber(
                        beamTable and beamTable.beamDamp,
                        beamTable and beamTable.damp,
                        globalBeam and globalBeam.beamDamp,
                        globalBeam and globalBeam.damp),
                    springExpansion = firstNumber(
                        beamTable and beamTable.beamSpringExpansion,
                        beamTable and beamTable.springExpansion,
                        globalBeam and globalBeam.beamSpringExpansion,
                        globalBeam and globalBeam.springExpansion),
                    dampExpansion = firstNumber(
                        beamTable and beamTable.beamDampExpansion,
                        beamTable and beamTable.dampExpansion,
                        globalBeam and globalBeam.beamDampExpansion,
                        globalBeam and globalBeam.dampExpansion),
                    id1 = resolveNodeCid((globalBeam and (globalBeam.id1 or globalBeam.id1cid))
                        or (beamTable and (beamTable.id1 or beamTable.id1cid))),
                    id2 = resolveNodeCid((globalBeam and (globalBeam.id2 or globalBeam.id2cid))
                        or (beamTable and (beamTable.id2 or beamTable.id2cid))),
                    precompression = nil,
                }
                if groupName == "side" then
                    entry.spring = firstNumber(entry.spring, wheelDef and wheelDef.wheelSideBeamSpring)
                    entry.damp = firstNumber(entry.damp, wheelDef and wheelDef.wheelSideBeamDamp)
                    entry.springExpansion = firstNumber(entry.springExpansion, wheelDef and wheelDef.wheelSideBeamSpringExpansion)
                    entry.dampExpansion = firstNumber(entry.dampExpansion, wheelDef and wheelDef.wheelSideBeamDampExpansion)
                    entry.precompression = firstNumber(wheelDef and wheelDef.wheelSideBeamPrecompression, 1.0)
                elseif groupName == "tread" then
                    entry.spring = firstNumber(entry.spring, wheelDef and wheelDef.wheelTreadBeamSpring)
                    entry.damp = firstNumber(entry.damp, wheelDef and wheelDef.wheelTreadBeamDamp)
                    entry.precompression = firstNumber(wheelDef and wheelDef.wheelTreadBeamPrecompression, 1.0)
                elseif groupName == "reinf" then
                    entry.precompression = firstNumber(wheelDef and wheelDef.wheelReinfBeamPrecompression, 1.0)
                    entry.spring = firstNumber(entry.spring,
                        wheelDef and wheelDef.wheelReinfBeamSpring,
                        wheelDef and wheelDef.wheelTreadReinfBeamSpring,
                        wheelDef and wheelDef.wheelSideReinfBeamSpring)
                    entry.damp = firstNumber(entry.damp,
                        wheelDef and wheelDef.wheelReinfBeamDamp,
                        wheelDef and wheelDef.wheelTreadReinfBeamDamp,
                        wheelDef and wheelDef.wheelSideReinfBeamDamp)
                end
                if entry.spring ~= nil or entry.damp ~= nil or entry.springExpansion ~= nil or entry.dampExpansion ~= nil then
                    self.cache[#self.cache + 1] = entry
                    seen[cid] = true
                    groupCounts[groupName] = (groupCounts[groupName] or 0) + 1
                    wheelSeen[tostring(wheelID)] = true
                    if entry.id1 ~= nil and entry.id2 ~= nil then
                        self.stats.endpointResolved = (self.stats.endpointResolved or 0) + 1
                    else
                        self.stats.endpointMissing = (self.stats.endpointMissing or 0) + 1
                    end
                end
            end
        end
    end

    for wheelKey, wheelDef in pairs(wheelDefs) do
        if type(wheelDef) == "table" then
            addGroup(wheelKey, wheelDef, "side", wheelDef.sideBeams)
            addGroup(wheelKey, wheelDef, "tread", wheelDef.treadBeams)
            addGroup(wheelKey, wheelDef, "reinf", wheelDef.reinfBeams or wheelDef.reinforcementBeams)
        end
    end

    local wheelCount = 0
    for _ in pairs(wheelSeen) do wheelCount = wheelCount + 1 end
    self.cacheReady = #self.cache > 0
    self.stats.cached = #self.cache
    self.stats.side = groupCounts.side or 0
    self.stats.tread = groupCounts.tread or 0
    self.stats.reinf = groupCounts.reinf or 0
    self.stats.wheelCount = wheelCount
    self.stats.lastError = self.cacheReady and "ready" or "no-generated-tyre-beams-found"
    if self.cacheReady then
        log("I", "luukstyrethermalsandwear", string.format(
            "Structure tuner cache ready: beams=%d wheels=%d side=%d tread=%d reinf=%d endpoints=%d/%d",
            #self.cache, wheelCount, self.stats.side, self.stats.tread, self.stats.reinf,
            self.stats.endpointResolved or 0, #self.cache))
    end
    return self.cacheReady
end

M._beamStructureTuner.classifyWheelAxle = function(wheelID, wheelName)
    local name = string.upper(tostring(wheelName or ""))
    local compact = string.gsub(name, "[^A-Z0-9]", "")
    if string.find(compact, "FRONT", 1, true) or compact == "FL" or compact == "FR"
        or string.find(compact, "WHEELFL", 1, true) or string.find(compact, "WHEELFR", 1, true)
        or string.find(compact, "TIREFL", 1, true) or string.find(compact, "TIREERONT", 1, true) then
        return "front"
    end
    if string.find(compact, "REAR", 1, true) or compact == "RL" or compact == "RR"
        or string.find(compact, "WHEELRL", 1, true) or string.find(compact, "WHEELRR", 1, true)
        or string.find(compact, "TIRERL", 1, true) or string.find(compact, "TIRERR", 1, true) then
        return "rear"
    end
    if string.match(compact, "^F[LR]%d*$") then return "front" end
    if string.match(compact, "^R[LR]%d*$") then return "rear" end
    return "unknown"
end

M._beamStructureTuner.sampleGeometry = function()
    local self = M._beamStructureTuner
    if not self.cacheReady and not self.rebuildCache() then return nil end
    if not obj then return nil end

    local function bucket(name, axle, wheelID)
        return {
            name = name, axle = axle, wheelID = wheelID,
            sums = {side = 0, tread = 0, reinf = 0},
            counts = {side = 0, tread = 0, reinf = 0}
        }
    end
    local function add(b, group, length)
        b.sums[group] = (b.sums[group] or 0) + length
        b.counts[group] = (b.counts[group] or 0) + 1
    end
    local function finish(b)
        if not b then return nil end
        return {
            name = b.name, axle = b.axle, wheelID = b.wheelID,
            sideM = b.counts.side > 0 and b.sums.side / b.counts.side or nil,
            treadM = b.counts.tread > 0 and b.sums.tread / b.counts.tread or nil,
            reinfM = b.counts.reinf > 0 and b.sums.reinf / b.counts.reinf or nil,
            sideCount = b.counts.side or 0,
            treadCount = b.counts.tread or 0,
            reinfCount = b.counts.reinf or 0,
        }
    end

    local allB = bucket("ALL", "all", nil)
    local frontB = bucket("FRONT", "front", nil)
    local rearB = bucket("REAR", "rear", nil)
    local wheelBuckets = {}

    for _, entry in ipairs(self.cache or {}) do
        local ok, length = pcall(function() return obj:getBeamLength(entry.cid) end)
        if ok and type(length) == "number" and length == length and length > 0 then
            local wheelKey = tostring(entry.wheelID)
            local axle = self.classifyWheelAxle(entry.wheelID, entry.wheelName)
            local wb = wheelBuckets[wheelKey]
            if not wb then
                wb = bucket(tostring(entry.wheelName or wheelKey), axle, entry.wheelID)
                wheelBuckets[wheelKey] = wb
            end
            add(allB, entry.group, length)
            add(wb, entry.group, length)
            if axle == "front" then add(frontB, entry.group, length)
            elseif axle == "rear" then add(rearB, entry.group, length) end
        end
    end

    local wheelsOut = {}
    for _, wb in pairs(wheelBuckets) do wheelsOut[#wheelsOut + 1] = finish(wb) end
    table.sort(wheelsOut, function(a, b)
        local ai, bi = finiteNumber(a and a.wheelID, 1e9), finiteNumber(b and b.wheelID, 1e9)
        if ai == bi then return tostring(a and a.name or "") < tostring(b and b.name or "") end
        return ai < bi
    end)

    local sample = {
        all = finish(allB), front = finish(frontB), rear = finish(rearB), wheels = wheelsOut
    }
    self.geometryLast = sample
    return sample
end

M._beamStructureTuner.captureGeometryBaseline = function()
    local self = M._beamStructureTuner
    local sample = self.sampleGeometry()
    if not sample then
        self.stats.lastError = "geometry-baseline-capture-failed"
        return false
    end
    local function copyBucket(b)
        if not b then return nil end
        return {
            name = b.name, axle = b.axle, wheelID = b.wheelID,
            sideM = b.sideM, treadM = b.treadM, reinfM = b.reinfM,
            sideCount = b.sideCount, treadCount = b.treadCount, reinfCount = b.reinfCount,
        }
    end
    local wheelMap = {}
    for _, w in ipairs(sample.wheels or {}) do wheelMap[tostring(w.wheelID)] = copyBucket(w) end
    self.geometryBaseline = {
        all = copyBucket(sample.all), front = copyBucket(sample.front), rear = copyBucket(sample.rear),
        wheels = wheelMap,
    }
    self.stats.lastError = "geometry-baseline-captured"
    log("I", "luukstyrethermalsandwear", string.format(
        "Structure geometry baseline: ALL tread=%.6fm FRONT=%.6fm REAR=%.6fm side=%.6fm",
        finiteNumber(sample.all and sample.all.treadM, 0),
        finiteNumber(sample.front and sample.front.treadM, 0),
        finiteNumber(sample.rear and sample.rear.treadM, 0),
        finiteNumber(sample.all and sample.all.sideM, 0)))
    return true
end

M._beamStructureTuner.getGeometryTelemetry = function(reuseLast)
    local self = M._beamStructureTuner
    local now = (reuseLast == true and self.geometryLast) or self.sampleGeometry() or self.geometryLast or {}
    local base = self.geometryBaseline or {}
    local function deltaPct(current, reference)
        current = finiteNumber(current, nil)
        reference = finiteNumber(reference, nil)
        if current == nil or reference == nil or math.abs(reference) < 1e-9 then return 0 end
        return (current / reference - 1) * 100
    end
    local function tele(n, b)
        n, b = n or {}, b or {}
        return {
            treadLengthMm = finiteNumber(n.treadM, 0) * 1000,
            sideLengthMm = finiteNumber(n.sideM, 0) * 1000,
            reinfLengthMm = finiteNumber(n.reinfM, 0) * 1000,
            treadDeltaPct = deltaPct(n.treadM, b.treadM),
            sideDeltaPct = deltaPct(n.sideM, b.sideM),
            reinfDeltaPct = deltaPct(n.reinfM, b.reinfM),
            treadCount = finiteNumber(n.treadCount, 0),
            sideCount = finiteNumber(n.sideCount, 0),
            reinfCount = finiteNumber(n.reinfCount, 0),
        }
    end
    local allT = tele(now.all or now, base.all or base)
    local out = {
        baselineCaptured = self.geometryBaseline ~= nil,
        all = allT,
        front = tele(now.front, base.front),
        rear = tele(now.rear, base.rear),
        wheels = {},
        treadLengthMm = allT.treadLengthMm,
        sideLengthMm = allT.sideLengthMm,
        reinfLengthMm = allT.reinfLengthMm,
        treadDeltaPct = allT.treadDeltaPct,
        sideDeltaPct = allT.sideDeltaPct,
        reinfDeltaPct = allT.reinfDeltaPct,
    }
    local baseWheels = base.wheels or {}
    for _, w in ipairs(now.wheels or {}) do
        local wt = tele(w, baseWheels[tostring(w.wheelID)])
        wt.wheelID = w.wheelID
        wt.name = w.name
        wt.axle = w.axle
        out.wheels[#out.wheels + 1] = wt
    end
    return out
end

M._beamStructureTuner.apply = function()
    local self = M._beamStructureTuner
    if not self.cacheReady and not self.rebuildCache() then
        self.pendingApply = true
        return false
    end
    if not obj then
        self.pendingApply = true
        self.stats.lastError = "vehicle-physics-object-unavailable"
        return false
    end

    local m = self.multipliers
    local applied, failed, skipped = 0, 0, 0
    local refApplied, refFailed = 0, 0
    local firstFailure = nil
    for _, entry in ipairs(self.cache) do
        local wheelState = wheels and wheels.wheels and wheels.wheels[entry.wheelID] or nil
        if wheelState and wheelState.isTireDeflated == true then
            skipped = skipped + 1
        else
            local spring, damp, springExp, dampExp = -1, -1, -1, -1
            if entry.group == "side" then
                local familySideScale = finiteNumber(self.wheelSideSpringScale[entry.wheelID], 1.0)
                if entry.spring ~= nil then spring = entry.spring * m.sideSpring * familySideScale end
                if entry.damp ~= nil then damp = entry.damp * m.sideDamp end
                if entry.springExpansion ~= nil then springExp = entry.springExpansion * m.sideExpansionSpring end
                if entry.dampExpansion ~= nil then dampExp = entry.dampExpansion * m.sideExpansionDamp end
            elseif entry.group == "tread" then
                local wheelScale = finiteNumber(self.wheelTreadSpringScale[entry.wheelID], 1.0)
                local owned = self.wheelTreadSpringOwned[entry.wheelID] == true
                local manualScale = owned and 1.0 or m.treadSpring
                local wheelDampScale = finiteNumber(self.wheelTreadDampScale[entry.wheelID], 1.0)
                local dampOwned = self.wheelTreadDampOwned[entry.wheelID] == true
                local manualDampScale = dampOwned and 1.0 or m.treadDamp
                if entry.spring ~= nil then spring = entry.spring * manualScale * wheelScale end
                if entry.damp ~= nil then damp = entry.damp * manualDampScale * wheelDampScale end
            else
                local familyReinfScale = finiteNumber(self.wheelReinfSpringScale[entry.wheelID], 1.0)
                if entry.spring ~= nil then spring = entry.spring * m.reinfSpring * familyReinfScale end
                if entry.damp ~= nil then damp = entry.damp * m.reinfDamp end
                if entry.springExpansion ~= nil then springExp = entry.springExpansion * m.reinfSpring * familyReinfScale end
                if entry.dampExpansion ~= nil then dampExp = entry.dampExpansion * m.reinfDamp end
            end

            local ok, err = pcall(function()
                obj:setBeamSpringDamp(entry.cid, spring, damp, springExp, dampExp)
            end)

            if entry.precompression ~= nil then
                local preScale = 1.0
                if entry.group == "side" then
                    preScale = m.sidePrecompression
                elseif entry.group == "tread" then
                    local wheelPreScale = finiteNumber(self.wheelTreadPrecompressionScale[entry.wheelID], 1.0)
                    local wheelPreOwned = self.wheelTreadPrecompressionOwned[entry.wheelID] == true
                    preScale = wheelPreOwned and wheelPreScale or m.treadPrecompression
                else
                    preScale = m.reinfPrecompression
                end
                local targetRefRatio = clamp(entry.precompression * finiteNumber(preScale, 1.0), 0.50, 1.50)
                local okRef, errRef = pcall(function()
                    obj:setBeamLengthRefRatio(entry.cid, targetRefRatio)
                end)
                if okRef then
                    refApplied = refApplied + 1
                else
                    refFailed = refFailed + 1
                    if firstFailure == nil then firstFailure = "setBeamLengthRefRatio: " .. tostring(errRef) end
                end
            end

            if ok then
                applied = applied + 1
            else
                failed = failed + 1
                if firstFailure == nil then firstFailure = tostring(err) end
            end
        end
    end
    self.stats.applied = applied
    self.stats.failed = failed
    self.stats.refApplied = refApplied
    self.stats.refFailed = refFailed
    self.stats.skippedDeflated = skipped
    self.stats.lastError = firstFailure or (applied > 0 and "applied"
        or (skipped > 0 and failed == 0 and "all-tyre-beams-skipped-deflated" or "zero-beams-applied"))
    if applied > 0 then self.revision = (self.revision or 0) + 1 end
    self.pendingApply = applied == 0 and skipped < #self.cache
    if failed > 0 or applied == 0 then
        log("W", "luukstyrethermalsandwear", string.format(
            "Structure tuner apply: cached=%d applied=%d failed=%d skipped=%d error=%s",
            self.stats.cached or 0, applied, failed, skipped, tostring(self.stats.lastError)))
    else
        log("I", "luukstyrethermalsandwear", string.format(
            "Structure tuner applied: beams=%d ref=%d revision=%d side=%.3f/%.3f tread=%.3f preT=%.3f reinf=%.3f",
            applied, refApplied, self.revision or 0, m.sideSpring, m.sideExpansionSpring, m.treadSpring, m.treadPrecompression, m.reinfSpring))
    end
    return applied > 0
end

M._beamStructureTuner.setWheelTreadScale = function(wheelID, scale, owned)
    local self = M._beamStructureTuner
    scale = clamp(finiteNumber(scale, 1.0), 0.0, 6.0)
    owned = owned == true
    local oldScale = finiteNumber(self.wheelTreadSpringScale[wheelID], 1.0)
    local oldOwned = self.wheelTreadSpringOwned[wheelID] == true
    self.wheelTreadSpringScale[wheelID] = scale
    self.wheelTreadSpringOwned[wheelID] = owned
    if math.abs(oldScale - scale) > 0.0005 or oldOwned ~= owned then
        self.pendingApply = true
        return true
    end
    return false
end

M._beamStructureTuner.applyWheelTreadSpringFast = function(wheelID, scale, dampScale, previousScale)
    local self = M._beamStructureTuner
    scale = clamp(finiteNumber(scale, 1.0), 0.0, 6.0)
    previousScale = clamp(finiteNumber(previousScale,
        finiteNumber(self.wheelTreadSpringScale[wheelID],1.0)),0.0,6.0)
    local fastDampScale = type(dampScale)=="number" and clamp(finiteNumber(dampScale,1.0),0.0,1.50) or nil
    if not self.cacheReady and not self.rebuildCache() then return false end
    if not obj then return false end

    local function writeDamping()
        if fastDampScale==nil then return true end
        local applied=0
        for _,entry in ipairs(self.cache) do
            if entry.group=="tread"
                and (tonumber(entry.wheelID) or entry.wheelID)==(tonumber(wheelID) or wheelID)
                and entry.damp~=nil then
                local wheelState=wheels and wheels.wheels and wheels.wheels[entry.wheelID] or nil
                if not (wheelState and wheelState.isTireDeflated==true) then
                    local ok=pcall(function()
                        obj:setBeamSpringDamp(entry.cid,-1,entry.damp*fastDampScale,-1,-1)
                    end)
                    if ok then applied=applied+1 end
                end
            end
        end
        return applied>0
    end

    local function writeSpring()
        local applied=0
        for _,entry in ipairs(self.cache) do
            if entry.group=="tread"
                and (tonumber(entry.wheelID) or entry.wheelID)==(tonumber(wheelID) or wheelID)
                and entry.spring~=nil then
                local wheelState=wheels and wheels.wheels and wheels.wheels[entry.wheelID] or nil
                if not (wheelState and wheelState.isTireDeflated==true) then
                    local ok=pcall(function()
                        obj:setBeamSpringDamp(entry.cid,entry.spring*scale,-1,-1,-1)
                    end)
                    if ok then applied=applied+1 end
                end
            end
        end
        return applied>0
    end

    if scale>previousScale+0.0005 then
        if not writeDamping() then return false end
        return writeSpring()
    elseif scale<previousScale-0.0005 then
        if not writeSpring() then return false end
        return writeDamping()
    end
    return writeDamping()
end

-- REWIND STABILITY STAGING.
-- Rewind/RESET_PHYSICS can rebuild a tyre at native beam parameters for one instant
-- before KTS restores the saved hot/cold tread spring. High-stiffness race-tyre
-- constructions can destabilise if the restored spring is applied before the matching
-- low-damping schedule has settled. This actuator writes
-- ONLY tread damping (spring=-1 means leave the current BeamNG spring untouched).
-- applyRestoredStructure() uses it immediately, then queues the saved spring +
M._beamStructureTuner.applyWheelTreadDampOnlyFast = function(wheelID, dampScale)
    local self = M._beamStructureTuner
    dampScale = clamp(finiteNumber(dampScale, 1.0), 0.0, 1.50)
    if not self.cacheReady and not self.rebuildCache() then return false end
    if not obj then return false end
    local applied = 0
    for _, entry in ipairs(self.cache) do
        if entry.group == "tread"
            and (tonumber(entry.wheelID) or entry.wheelID) == (tonumber(wheelID) or wheelID)
            and entry.damp ~= nil then
            local wheelState = wheels and wheels.wheels and wheels.wheels[entry.wheelID] or nil
            if not (wheelState and wheelState.isTireDeflated == true) then
                local ok = pcall(function()
                    obj:setBeamSpringDamp(entry.cid, -1, entry.damp * dampScale, -1, -1)
                end)
                if ok then applied = applied + 1 end
            end
        end
    end
    return applied > 0
end

M._beamStructureTuner.clearWheelTreadScale = function(wheelID)
    return M._beamStructureTuner.setWheelTreadScale(wheelID, 1.0, false)
end

M._beamStructureTuner.setWheelFamilyBaseScales = function(wheelID, sideScale, reinfScale)
    local self = M._beamStructureTuner
    sideScale = clamp(finiteNumber(sideScale, 1.0), 0.0, 2.0)
    reinfScale = clamp(finiteNumber(reinfScale, 1.0), 0.0, 2.0)
    local oldSide = finiteNumber(self.wheelSideSpringScale[wheelID], 1.0)
    local oldReinf = finiteNumber(self.wheelReinfSpringScale[wheelID], 1.0)
    self.wheelSideSpringScale[wheelID] = sideScale
    self.wheelReinfSpringScale[wheelID] = reinfScale
    if math.abs(oldSide - sideScale) > 0.0005 or math.abs(oldReinf - reinfScale) > 0.0005 then
        self.pendingApply = true
        return true
    end
    return false
end

M._beamStructureTuner.clearWheelFamilyBaseScales = function(wheelID)
    return M._beamStructureTuner.setWheelFamilyBaseScales(wheelID, 1.0, 1.0)
end

M._beamStructureTuner.setWheelTreadDampScale = function(wheelID, scale, owned)
    local self = M._beamStructureTuner
    scale = clamp(finiteNumber(scale, 1.0), 0.0, 1.50)
    owned = owned == true
    local oldScale = finiteNumber(self.wheelTreadDampScale[wheelID], 1.0)
    local oldOwned = self.wheelTreadDampOwned[wheelID] == true
    self.wheelTreadDampScale[wheelID] = scale
    self.wheelTreadDampOwned[wheelID] = owned
    if math.abs(oldScale - scale) > 0.0005 or oldOwned ~= owned then
        self.pendingApply = true
        return true
    end
    return false
end

M._beamStructureTuner.clearWheelTreadDampScale = function(wheelID)
    return M._beamStructureTuner.setWheelTreadDampScale(wheelID, 1.0, false)
end

M._beamStructureTuner.setWheelTreadPrecompressionScale = function(wheelID, scale, owned)
    local self = M._beamStructureTuner
    scale = clamp(finiteNumber(scale, 1.0), 0.50, 1.20)
    owned = owned == true
    local oldScale = finiteNumber(self.wheelTreadPrecompressionScale[wheelID], 1.0)
    local oldOwned = self.wheelTreadPrecompressionOwned[wheelID] == true
    self.wheelTreadPrecompressionScale[wheelID] = scale
    self.wheelTreadPrecompressionOwned[wheelID] = owned
    if math.abs(oldScale - scale) > 0.00002 or oldOwned ~= owned then
        self.pendingApply = true
        return true
    end
    return false
end

M._beamStructureTuner.clearWheelTreadPrecompressionScale = function(wheelID)
    return M._beamStructureTuner.setWheelTreadPrecompressionScale(wheelID, 1.0, false)
end

M._beamStructureTuner.setAxleTreadPrecompression = function(frontScale, rearScale, owned)
    local self = M._beamStructureTuner
    local changed = false
    for wheelID, wr in pairs(wheels and wheels.wheelRotators or {}) do
        local axle = self.classifyWheelAxle(wheelID, wr and wr.name)
        local scale = axle == "front" and frontScale or (axle == "rear" and rearScale or 1.0)
        if axle == "front" or axle == "rear" then
            if self.setWheelTreadPrecompressionScale(wheelID, scale, owned) then changed = true end
        end
    end
    if changed then self.apply() end
    return changed
end

M._beamStructureTuner.clearAxleTreadPrecompression = function()
    local self = M._beamStructureTuner
    local changed = false
    for wheelID, _ in pairs(wheels and wheels.wheelRotators or {}) do
        if self.clearWheelTreadPrecompressionScale(wheelID) then changed = true end
    end
    if changed then self.apply() end
    return changed
end

M._beamStructureTuner.setMultiplier = function(name, value)
    local self = M._beamStructureTuner
    if self.multipliers[name] == nil then return false end
    local rawValue = value
    if type(rawValue) == "number" then
        value = rawValue
    elseif type(rawValue) == "string" then
        value = tonumber(rawValue)
    else
        value = nil
    end
    if not value or value ~= value or value == math.huge or value == -math.huge then return false end
    if value < 0 then value = 0 elseif value > 2 then value = 2 end
    self.multipliers[name] = value
    self.pendingApply = true
    self.apply()
    return value
end

M._beamStructureTuner.resetMultipliers = function()
    for key, _ in pairs(M._beamStructureTuner.multipliers) do
        M._beamStructureTuner.multipliers[key] = 1.0
    end
    M._beamStructureTuner.wheelSideSpringScale = {}
    M._beamStructureTuner.wheelReinfSpringScale = {}
    M._beamStructureTuner.pendingApply = true
    M._beamStructureTuner.apply()
end

M._beamStructureTuner.update = function()
    if M._beamStructureTuner.pendingApply then M._beamStructureTuner.apply() end
end
-- -------------------------------------------------------------------------

local function getNonWearableTreadReserveM(nominalDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local requested = math.max(finiteNumber(M._tread1D and M._tread1D.nonWearableReserveM, 0.00050), 0.00010)
    return clamp(requested, 0.00010, nominal * 0.35)
end

local function conditionToPhysicalTreadDepthM(conditionPercent, nominalDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local reserve = getNonWearableTreadReserveM(nominal)
    local usable = math.max(nominal - reserve, 1e-6)
    local health = clamp(finiteNumber(conditionPercent, 100) / 100, 0, 1)
    return reserve + usable * health
end

local function physicalTreadDepthToCondition(depthM, nominalDepthM)
    local nominal = math.max(finiteNumber(nominalDepthM, 0.006), 0.001)
    local reserve = getNonWearableTreadReserveM(nominal)
    local usable = math.max(nominal - reserve, 1e-6)
    return clamp((finiteNumber(depthM, nominal) - reserve) / usable * 100, 0, 100)
end

M._tread1D = M._tread1D or {}
M._tread1D.capturePresetDepthHealth = function(data, physical)
    if type(data) ~= "table" then return nil end
    local nominal = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
    local fallbackDepth = conditionToPhysicalTreadDepthM(data.condition, nominal)
    local state = { nominalDepthM = nominal, zoneHealth = {} }
    local depths = type(data.tread_remaining_depth_m) == "table" and data.tread_remaining_depth_m or nil
    for zone = 1, 3 do
        local depth = depths and depths[zone] or fallbackDepth
        state.zoneHealth[zone] = physicalTreadDepthToCondition(depth, nominal) / 100
    end
    return state
end

M._tread1D.applyPresetDepthHealth = function(data, state, physical)
    if type(data) ~= "table" or type(state) ~= "table" then return false end
    local nominal = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
    data.tread_remaining_depth_m = type(data.tread_remaining_depth_m) == "table" and data.tread_remaining_depth_m or {}
    local sum = 0
    for zone = 1, 3 do
        local health = clamp(finiteNumber(state.zoneHealth and state.zoneHealth[zone], finiteNumber(data.condition, 100) / 100), 0, 1)
        local depth = conditionToPhysicalTreadDepthM(health * 100, nominal)
        data.tread_remaining_depth_m[zone] = depth
        sum = sum + depth
    end
    local meanDepth = sum / 3
    data.condition = physicalTreadDepthToCondition(meanDepth, nominal)
    data.tread_nominal_depth_m = nominal
    data.tread_mean_remaining_depth_m = meanDepth
    data.tread_nonwearable_reserve_m = getNonWearableTreadReserveM(nominal)
    data.tread_wearable_remaining_m = math.max(meanDepth - data.tread_nonwearable_reserve_m, 0)
    if M._tread1D.deriveTemps and type(data.tread_field) == "table" then
        M._tread1D.deriveTemps(data, physical)
    end
    return true
end

M._tread1D.setUniform = function(data, target, physical)
    if type(data)~="table" then return end
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local fallback=conditionToPhysicalTreadDepthM(data.condition,nominal)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}; data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}
    for z=1,3 do
        local depth=finiteNumber(data.tread_remaining_depth_m[z],fallback); local n=math.max(math.floor(finiteNumber(M._tread1D.cells,12)),1)
        if physical then n=M._tread1D.getCellTopologyForDepth(depth,physical,true).activeCount end
        data.tread_field[z]={}; for j=1,n do data.tread_field[z][j]=target end; data.surface_boundary_temp[z]=target
    end
    if physical then M._tread1D.ensureAdaptiveField(data,physical) end
end

-- Research-aligned operating-start preheat. Research refs: [R5][R13]. "Working temperature" remains
-- the compound/grip target reached under load; the button no longer claims that the
-- entire tyre, carcass and inflation gas should begin at that same temperature.
M._tread1D.setOperatingStartPreheat = function(data, workingTarget, physical)
    if type(data)~="table" then return end
    local ambient=finiteNumber(ENV_TEMP,20); local target=finiteNumber(workingTarget,ambient); local delta=target-ambient; local cfg=M._physicalThermal or {}
    local surfaceT=ambient+delta*clamp(finiteNumber(cfg.preheatSurfaceFraction,0.85),0,1.2); local roadT=ambient+delta*clamp(finiteNumber(cfg.preheatRoadCellFraction,0.80),0,1.2); local deepT=ambient+delta*clamp(finiteNumber(cfg.preheatDeepTreadFraction,0.55),0,1.2); local coreT=ambient+delta*clamp(finiteNumber(cfg.preheatCoreFraction,0.40),0,1.2); local airT=ambient+delta*clamp(finiteNumber(cfg.preheatAirFraction,0),0,1.2)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local fallback=conditionToPhysicalTreadDepthM(data.condition,nominal)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}; data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}; data.surface_temp=type(data.surface_temp)=="table" and data.surface_temp or {}
    for z=1,3 do
        local depth=clamp(finiteNumber(data.tread_remaining_depth_m[z],fallback),getNonWearableTreadReserveM(nominal),nominal); data.tread_remaining_depth_m[z]=depth; local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true); local field={}; local cursor=0
        for j=1,topo.activeCount do local dx=topo.thicknessM[j]; local x=cursor+0.5*dx; cursor=cursor+dx; local u=clamp(x/math.max(depth,1e-9),0,1); field[j]=roadT+(deepT-roadT)*(u^0.85) end
        data.tread_field[z]=field; data.surface_boundary_temp[z]=surfaceT; data.surface_temp[z]=surfaceT
    end
    data.temp=type(data.temp)=="table" and data.temp or {ambient,ambient,ambient,ambient}; data.temp[4]=coreT; data.air_temp=airT; data.rim_temp=finiteNumber(data.rim_temp,ambient); data.flash_temp=surfaceT; M._tread1D.ensureAdaptiveField(data,physical)
    return surfaceT,coreT,airT
end

M._tread1D.getWearOffRegenFillTemp = function(data, profile)
    local ambient = finiteNumber(ENV_TEMP, 20)
    local working = finiteNumber(data and data.working_temp,
        finiteNumber(profile and profile.workingTemp, ambient))
    local coreFraction = clamp(finiteNumber(
        M._physicalThermal and M._physicalThermal.preheatCoreFraction, 0.40), 0, 1.2)
    return ambient + (working - ambient) * coreFraction
end

M._tread1D.setOperatingWindowPreheatProfile = function(data, workingTarget, physical)
    if type(data)~="table" then return end
    local ambient=finiteNumber(ENV_TEMP,20); local target=finiteNumber(workingTarget,ambient); local delta=target-ambient; local cfg=M._physicalThermal or {}
    local deepT=ambient+delta*clamp(finiteNumber(cfg.preheatDeepTreadFraction,0.55),0,1.2); local coreT=ambient+delta*clamp(finiteNumber(cfg.preheatCoreFraction,0.40),0,1.2); local airT=ambient+delta*clamp(finiteNumber(cfg.preheatAirFraction,0),0,1.2)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local decay=math.max(finiteNumber(physical and physical.gripDepthDecayM,M._tread1D.gripDepthDecayM),1e-6)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}; data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}; data.surface_temp=type(data.surface_temp)=="table" and data.surface_temp or {}
    for z=1,3 do
        local depth=clamp(finiteNumber(data.tread_remaining_depth_m[z],nominal),getNonWearableTreadReserveM(nominal),nominal); data.tread_remaining_depth_m[z]=depth; local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true); local warm=math.min(3*decay,depth); local field={}; local cursor=0
        for j=1,topo.activeCount do local dx=topo.thicknessM[j]; local x=cursor+0.5*dx; cursor=cursor+dx; if x<=warm then field[j]=target else local u=clamp((x-warm)/math.max(depth-warm,1e-6),0,1); field[j]=target+(deepT-target)*(u^0.85) end end
        data.tread_field[z]=field; data.surface_boundary_temp[z]=target; data.surface_temp[z]=target
    end
    data.temp=type(data.temp)=="table" and data.temp or {target,target,target,coreT}; data.temp[4]=coreT; data.air_temp=airT; data.rim_temp=finiteNumber(data.rim_temp,ambient); data.flash_temp=target; M._tread1D.ensureAdaptiveField(data,physical); M._tread1D.deriveTemps(data,physical)
    return target,coreT,airT
end

M._tread1D.setPeakGripHoldProfile = function(data, workingTarget, physical)
    if type(data)~="table" then return end
    local ambient=finiteNumber(ENV_TEMP,20); local target=finiteNumber(workingTarget,ambient); local delta=target-ambient; local cfg=M._physicalThermal or {}
    local deepT=ambient+delta*clamp(finiteNumber(cfg.preheatDeepTreadFraction,0.55),0,1.2); local coreT=ambient+delta*clamp(finiteNumber(cfg.preheatCoreFraction,0.40),0,1.2); local airT=ambient+delta*clamp(finiteNumber(cfg.preheatAirFraction,0),0,1.2)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local decay=math.max(finiteNumber(physical and physical.gripDepthDecayM,M._tread1D.gripDepthDecayM),1e-6)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}; data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}; data.surface_temp=type(data.surface_temp)=="table" and data.surface_temp or {}
    for z=1,3 do
        local depth=clamp(finiteNumber(data.tread_remaining_depth_m[z],nominal),getNonWearableTreadReserveM(nominal),nominal); data.tread_remaining_depth_m[z]=depth; local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true); local warm=math.min(3*decay,depth); local field={}; local cursor=0
        for j=1,topo.activeCount do local dx=topo.thicknessM[j]; local x=cursor+0.5*dx; cursor=cursor+dx; if x<=warm then field[j]=target else local u=clamp((x-warm)/math.max(depth-warm,1e-6),0,1); field[j]=target+(deepT-target)*(u^0.85) end end
        data.tread_field[z]=field; data.surface_boundary_temp[z]=target; data.surface_temp[z]=target
    end
    data.temp=type(data.temp)=="table" and data.temp or {target,target,target,coreT}; data.temp[4]=coreT; data.air_temp=airT; data.rim_temp=finiteNumber(data.rim_temp,ambient); data.flash_temp=target; M._tread1D.ensureAdaptiveField(data,physical); M._tread1D.deriveTemps(data,physical)
    return target,coreT,airT
end

M._tread1D.ensureField = function(data, physical)
    if type(data) ~= "table" then return end
    local n = math.max(math.floor(finiteNumber(M._tread1D.cells, 12)), 4)
    local nominalDepth = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
    data.tread_field = type(data.tread_field) == "table" and data.tread_field or {}
    data.tread_remaining_depth_m = type(data.tread_remaining_depth_m) == "table" and data.tread_remaining_depth_m or {}
    data.tread_bulk_temp = type(data.tread_bulk_temp) == "table" and data.tread_bulk_temp or {}
    data.surface_boundary_temp = type(data.surface_boundary_temp) == "table" and data.surface_boundary_temp or {}
    local reserveDepth = getNonWearableTreadReserveM(nominalDepth)
    local depthFromCondition = conditionToPhysicalTreadDepthM(data.condition, nominalDepth)
    for zone = 1, 3 do
        local depth = finiteNumber(data.tread_remaining_depth_m[zone], depthFromCondition)
        data.tread_remaining_depth_m[zone] = clamp(depth, reserveDepth, nominalDepth)
        local field = data.tread_field[zone]
        if type(field) ~= "table" or #field ~= n then
            local surfaceT = finiteNumber(data.surface_temp and data.surface_temp[zone], ENV_TEMP)
            local gripT = finiteNumber(data.temp and data.temp[zone], surfaceT)
            local coreT = finiteNumber(data.temp and data.temp[4], gripT)
            field = {}
            for j = 1, n do
                local u = (j - 0.5) / n
                if u <= 0.25 then
                    field[j] = surfaceT + (gripT - surfaceT) * (u / 0.25)
                else
                    field[j] = gripT + (coreT - gripT) * ((u - 0.25) / 0.75)
                end
            end
            data.tread_field[zone] = field
        else
            for j = 1, n do field[j] = finiteNumber(field[j], ENV_TEMP) end
        end
    end
end

M._tread1D.getCellRateDivisor = function(cellIndex)
    local j=math.max(math.floor(finiteNumber(cellIndex,1)),1)
    local map=M._tread1D.cellRateDivisors or {1,2,2,4,4,4,8,8,8,8,12,12}
    return math.max(math.floor(finiteNumber(map[math.min(j,#map)],12)),1)
end

M._tread1D.getAdaptiveStartDepthM = function(physical)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001)
    return nominal*clamp(finiteNumber(M._tread1D.adaptiveStartDepthRatio,0.50),0.1,0.9)
end

M._tread1D.getAdaptiveReferenceCellThicknessM = function(physical)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001)
    return nominal*clamp(finiteNumber(M._tread1D.adaptiveStartDepthRatio,0.50),0.1,0.9)
        / math.max(math.floor(finiteNumber(M._tread1D.cells,12)),1)
end

M._tread1D.getCellTopologyForDepth = function(depthM, physical, allowAdaptive, out)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001)
    local reserve=getNonWearableTreadReserveM(nominal)
    local depth=clamp(finiteNumber(depthM,nominal),reserve,nominal)
    local fullN=math.max(math.floor(finiteNumber(M._tread1D.cells,12)),1)
    local startDepth=nominal*clamp(finiteNumber(M._tread1D.adaptiveStartDepthRatio,0.50),0.1,0.9)
    local refDx=startDepth/fullN
    local adaptive=allowAdaptive~=false and M._tread1D.adaptiveCellRetirementEnabled~=false
        and depth<=startDepth+1e-10
    local topo=type(out)=="table" and out or {}
    local thickness=type(topo.thicknessM)=="table" and topo.thicknessM or {}
    topo.thicknessM=thickness
    local n=fullN; local partial=depth/fullN
    if adaptive then
        n=clamp(math.ceil(depth/math.max(refDx,1e-9)-1e-10),1,fullN)
        partial=depth-(n-1)*refDx
        if partial<=math.max(finiteNumber(M._tread1D.adaptiveRetirementEpsilonM,1e-8),1e-10) and n>1 then
            n=n-1; partial=refDx
        end
        partial=clamp(partial,math.min(refDx,1e-8),refDx)
        thickness[1]=partial
        for j=2,n do thickness[j]=refDx end
    else
        local dx=depth/fullN; partial=dx
        for j=1,fullN do thickness[j]=dx end
    end
    for j=n+1,#thickness do thickness[j]=nil end
    topo.adaptive=adaptive==true; topo.nominalDepthM=nominal; topo.remainingDepthM=depth
    topo.startDepthM=startDepth; topo.referenceCellThicknessM=refDx; topo.activeCount=n
    topo.surfacePartialThicknessM=partial
    return topo
end

M._tread1D.buildZoneCellGeometry = function(data, physical, zone, areaM2, density, cp, out)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001)
    local reserve=getNonWearableTreadReserveM(nominal)
    local depth=clamp(finiteNumber(data and data.tread_remaining_depth_m and data.tread_remaining_depth_m[zone],nominal),reserve,nominal)
    local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true,out)
    local area=math.max(finiteNumber(areaM2,0.05),1e-6)
    local rho=math.max(finiteNumber(density,M._physicalThermal.rubberDensity),100)
    local heatCp=math.max(finiteNumber(cp,M._physicalThermal.rubberCp),100)
    topo.startM=type(topo.startM)=="table" and topo.startM or {}
    topo.endM=type(topo.endM)=="table" and topo.endM or {}
    topo.centerM=type(topo.centerM)=="table" and topo.centerM or {}
    topo.fillFraction=type(topo.fillFraction)=="table" and topo.fillFraction or {}
    topo.capacityJPerK=type(topo.capacityJPerK)=="table" and topo.capacityJPerK or {}
    local cursor=0
    for j=1,topo.activeCount do
        local dx=math.max(finiteNumber(topo.thicknessM[j],depth/topo.activeCount),1e-9)
        topo.startM[j]=cursor; topo.endM[j]=math.min(cursor+dx,depth); topo.centerM[j]=0.5*(topo.startM[j]+topo.endM[j])
        topo.fillFraction[j]=M._treadGrooveGeometry.getRubberFillFractionOverLiveDepth(physical,nominal,depth,topo.startM[j],topo.endM[j])
        topo.capacityJPerK[j]=math.max(rho*heatCp*area*math.max(topo.endM[j]-topo.startM[j],1e-9)*topo.fillFraction[j],0.1)
        cursor=topo.endM[j]
    end
    for j=topo.activeCount+1,#topo.startM do topo.startM[j]=nil end
    for j=topo.activeCount+1,#topo.endM do topo.endM[j]=nil end
    for j=topo.activeCount+1,#topo.centerM do topo.centerM[j]=nil end
    for j=topo.activeCount+1,#topo.fillFraction do topo.fillFraction[j]=nil end
    for j=topo.activeCount+1,#topo.capacityJPerK do topo.capacityJPerK[j]=nil end
    topo.areaM2=area; topo.density=rho; topo.cp=heatCp
    return topo
end

M._tread1D.getGripDepthWeightFromGeometry = function(zoneGeom, cellIndex, decayM)
    if type(zoneGeom)~="table" then return 0 end
    local j=math.floor(finiteNumber(cellIndex,1))
    return M._tread1D.getGripDepthBoundsWeight(finiteNumber(zoneGeom.startM and zoneGeom.startM[j],0),
        finiteNumber(zoneGeom.endM and zoneGeom.endM[j],0),decayM)
end

M._tread1D.exactRCExchangeJ = function(tempA, capA, tempB, capB, conductanceWPerK, dt)
    local ca=math.max(finiteNumber(capA,0),1e-9); local cb=math.max(finiteNumber(capB,0),1e-9)
    local g=math.max(finiteNumber(conductanceWPerK,0),0); local step=math.max(finiteNumber(dt,0),0)
    if g<=0 or step<=0 then return 0 end
    local d0=finiteNumber(tempA,0)-finiteNumber(tempB,0); if math.abs(d0)<=1e-12 then return 0 end
    local inv=1/ca+1/cb; local d1=d0*math.exp(-g*inv*step)
    return (d0-d1)/math.max(inv,1e-18)
end

M._tread1D.applyEnergyJ = function(temp, capacity, energyJ, lo, hi)
    local c=math.max(finiteNumber(capacity,0),0.1)
    return clamp(finiteNumber(temp,ENV_TEMP)+finiteNumber(energyJ,0)/c,finiteNumber(lo,ENV_TEMP-10),finiteNumber(hi,M._tread1D.maxCellTemp))
end

M._tread1D.exactBoundaryExchangeJ = function(temp, capacity, boundaryTemp, conductanceWPerK, dt)
    local c=math.max(finiteNumber(capacity,0),0.1)
    local g=math.max(finiteNumber(conductanceWPerK,0),0)
    local step=math.max(finiteNumber(dt,0),0)
    if g<=0 or step<=0 then return 0 end
    local delta=finiteNumber(temp,ENV_TEMP)-finiteNumber(boundaryTemp,ENV_TEMP)
    if math.abs(delta)<=1e-12 then return 0 end
    return c*delta*(1-math.exp(-g*step/c))
end

M._tread1D.remapZoneConservative = function(data, physical, zone, oldDepthM, newDepthM, removedDepthM, fillTemp, areaM2, density, cp)
    local oldField=type(data.tread_field and data.tread_field[zone])=="table" and data.tread_field[zone] or {fillTemp}
    local oldDepth=math.max(finiteNumber(oldDepthM,0.001),1e-9); local newDepth=math.max(finiteNumber(newDepthM,oldDepth),1e-9)
    local saved=data.tread_remaining_depth_m[zone]
    data.tread_remaining_depth_m[zone]=oldDepth; local oldGeom=M._tread1D.buildZoneCellGeometry(data,physical,zone,areaM2,density,cp)
    data.tread_remaining_depth_m[zone]=newDepth; local newGeom=M._tread1D.buildZoneCellGeometry(data,physical,zone,areaM2,density,cp)
    data.tread_remaining_depth_m[zone]=saved
    local shift=math.max(finiteNumber(removedDepthM,0),0); local result={}; local retainedOldJ=0; local newEnergyJ=0
    for j=1,newGeom.activeCount do
        local oldA=newGeom.startM[j]+shift; local oldB=newGeom.endM[j]+shift; local energy=0
        for k=1,oldGeom.activeCount do
            local overlap=math.max(math.min(oldB,oldGeom.endM[k])-math.max(oldA,oldGeom.startM[k]),0)
            if overlap>0 then
                local oldDx=math.max(oldGeom.endM[k]-oldGeom.startM[k],1e-12)
                energy=energy+oldGeom.capacityJPerK[k]*finiteNumber(oldField[k],fillTemp)*overlap/oldDx
            end
        end
        result[j]=clamp(energy/math.max(newGeom.capacityJPerK[j],0.1),ENV_TEMP-10,M._tread1D.maxCellTemp)
        newEnergyJ=newEnergyJ+result[j]*newGeom.capacityJPerK[j]
    end
    local oldTotalJ=0
    for k=1,oldGeom.activeCount do oldTotalJ=oldTotalJ+finiteNumber(oldField[k],fillTemp)*oldGeom.capacityJPerK[k] end
    for k=1,oldGeom.activeCount do
        local overlap=math.max(math.min(oldGeom.endM[k],shift+newDepth)-math.max(oldGeom.startM[k],shift),0)
        if overlap>0 then retainedOldJ=retainedOldJ+oldGeom.capacityJPerK[k]*finiteNumber(oldField[k],fillTemp)*overlap/math.max(oldGeom.endM[k]-oldGeom.startM[k],1e-12) end
    end
    return result,oldGeom,newGeom,oldTotalJ-retainedOldJ,newEnergyJ-retainedOldJ
end

M._tread1D.ensureAdaptiveField = function(data, physical)
    if type(data)~="table" then return end
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local reserve=getNonWearableTreadReserveM(nominal)
    local fallbackDepth=conditionToPhysicalTreadDepthM(data.condition,nominal)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}
    data.tread_active_cell_count=type(data.tread_active_cell_count)=="table" and data.tread_active_cell_count or {}; data.tread_surface_partial_cell_m=type(data.tread_surface_partial_cell_m)=="table" and data.tread_surface_partial_cell_m or {}; data.tread_adaptive_mode=type(data.tread_adaptive_mode)=="table" and data.tread_adaptive_mode or {}
    data._treadEnsureTopoScratch=type(data._treadEnsureTopoScratch)=="table" and data._treadEnsureTopoScratch or {{},{},{}}
    for z=1,3 do
        local depth=clamp(finiteNumber(data.tread_remaining_depth_m[z],fallbackDepth),reserve,nominal); data.tread_remaining_depth_m[z]=depth
        local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true,data._treadEnsureTopoScratch[z]); local field=data.tread_field[z]
        if type(field)~="table" or #field~=topo.activeCount then
            local old=type(field)=="table" and field or {}; local surfaceT=finiteNumber(data.surface_temp and data.surface_temp[z],finiteNumber(old[1],ENV_TEMP)); local gripT=finiteNumber(data.temp and data.temp[z],surfaceT); local coreT=finiteNumber(data.temp and data.temp[4],gripT)
            field={}; local cursor=0
            for j=1,topo.activeCount do
                local dx=topo.thicknessM[j]; local x=cursor+0.5*dx; cursor=cursor+dx; local u=clamp(x/math.max(depth,1e-9),0,1)
                if old[j]~=nil then field[j]=finiteNumber(old[j],surfaceT) elseif u<=0.25 then field[j]=surfaceT+(gripT-surfaceT)*(u/0.25) else field[j]=gripT+(coreT-gripT)*((u-0.25)/0.75) end
            end
            data.tread_field[z]=field
        end
        data.tread_active_cell_count[z]=topo.activeCount; data.tread_surface_partial_cell_m[z]=topo.surfacePartialThicknessM; data.tread_adaptive_mode[z]=topo.adaptive
    end
end

M._tread1D.ensureField = function(data, physical)
    if type(data)~="table" then return end
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001); local reserve=getNonWearableTreadReserveM(nominal)
    local fallbackDepth=conditionToPhysicalTreadDepthM(data.condition,nominal)
    data.tread_field=type(data.tread_field)=="table" and data.tread_field or {}; data.tread_remaining_depth_m=type(data.tread_remaining_depth_m)=="table" and data.tread_remaining_depth_m or {}
    data.tread_bulk_temp=type(data.tread_bulk_temp)=="table" and data.tread_bulk_temp or {}; data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}
    data.tread_active_cell_count=type(data.tread_active_cell_count)=="table" and data.tread_active_cell_count or {}; data.tread_surface_partial_cell_m=type(data.tread_surface_partial_cell_m)=="table" and data.tread_surface_partial_cell_m or {}; data.tread_adaptive_mode=type(data.tread_adaptive_mode)=="table" and data.tread_adaptive_mode or {}
    data._treadEnsureTopoScratch=type(data._treadEnsureTopoScratch)=="table" and data._treadEnsureTopoScratch or {{},{},{}}
    for z=1,3 do
        local depth=clamp(finiteNumber(data.tread_remaining_depth_m[z],fallbackDepth),reserve,nominal); data.tread_remaining_depth_m[z]=depth
        local topo=M._tread1D.getCellTopologyForDepth(depth,physical,true,data._treadEnsureTopoScratch[z]); local field=data.tread_field[z]
        if type(field)~="table" or #field~=topo.activeCount then
            local old=type(field)=="table" and field or {}; local surfaceT=finiteNumber(data.surface_temp and data.surface_temp[z],finiteNumber(old[1],ENV_TEMP)); local gripT=finiteNumber(data.temp and data.temp[z],surfaceT); local coreT=finiteNumber(data.temp and data.temp[4],gripT)
            field={}; local cursor=0
            for j=1,topo.activeCount do
                local dx=topo.thicknessM[j]; local x=cursor+0.5*dx; cursor=cursor+dx; local u=clamp(x/math.max(depth,1e-9),0,1)
                if old[j]~=nil then field[j]=finiteNumber(old[j],surfaceT) elseif u<=0.25 then field[j]=surfaceT+(gripT-surfaceT)*(u/0.25) else field[j]=gripT+(coreT-gripT)*((u-0.25)/0.75) end
            end
            data.tread_field[z]=field
        else for j=1,topo.activeCount do field[j]=finiteNumber(field[j],ENV_TEMP) end end
        data.tread_active_cell_count[z]=topo.activeCount; data.tread_surface_partial_cell_m[z]=topo.surfacePartialThicknessM; data.tread_adaptive_mode[z]=topo.adaptive
    end
end

M._tread1D.getWearDepthHeatScales = function(data, physical)
    local cfg = M._tread1D.wearDepthHeatCoupling or {}
    if cfg.enabled == false then
        return {
            depthRatio = 1.0, volumeFactor = 1.0,
            rolling = 1.0, longitudinal = 1.0, lateral = 1.0
        }
    end

    local nominalDepth = math.max(
        M._wearResearch.finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
    local reserveDepth = getNonWearableTreadReserveM(nominalDepth)
    local depthSum = 0
    local depthTable = data and data.tread_remaining_depth_m
    for zone = 1, 3 do
        local depth = M._wearResearch.finiteNumber(
            type(depthTable) == "table" and depthTable[zone], nominalDepth)
        depthSum = depthSum + M._wearResearch.clamp(depth, reserveDepth, nominalDepth)
    end

    local meanDepth = depthSum / 3
    local depthRatio = M._wearResearch.clamp(meanDepth / nominalDepth,
        reserveDepth / nominalDepth, 1.0)
    local exponent = math.max(M._wearResearch.finiteNumber(cfg.depthExponent, 1.0), 0)
    local volumeFactor = depthRatio ^ exponent

    local rollingFraction = M._wearResearch.clamp(
        M._wearResearch.finiteNumber(cfg.rollingTreadDependentFraction, 0.25), 0, 1)
    local longitudinalFraction = M._wearResearch.clamp(
        M._wearResearch.finiteNumber(cfg.longitudinalTreadDependentFraction, 0.58), 0, 1)
    local lateralFraction = M._wearResearch.clamp(
        M._wearResearch.finiteNumber(cfg.lateralTreadDependentFraction, 0.65), 0, 1)

    return {
        depthRatio = depthRatio,
        volumeFactor = volumeFactor,
        rolling = 1 - rollingFraction * (1 - volumeFactor),
        longitudinal = 1 - longitudinalFraction * (1 - volumeFactor),
        lateral = 1 - lateralFraction * (1 - volumeFactor),
    }
end

M._tread1D.sampleField = function(field, depthM, totalDepthM, fillTemp)
    local n = #field
    if n < 1 then return fillTemp end
    local depth = math.max(finiteNumber(totalDepthM, 0.001), 1e-6)
    local x = finiteNumber(depthM, 0)
    local dx = depth / n
    if x <= 0.5 * dx then return finiteNumber(field[1], fillTemp) end
    if x >= depth - 0.5 * dx then
        if x > depth then return fillTemp end
        return finiteNumber(field[n], fillTemp)
    end
    local fIndex = x / dx + 0.5
    local i0 = clamp(math.floor(fIndex), 1, n)
    local i1 = clamp(i0 + 1, 1, n)
    local frac = clamp(fIndex - i0, 0, 1)
    local a = finiteNumber(field[i0], fillTemp)
    local b = finiteNumber(field[i1], fillTemp)
    return a + (b - a) * frac
end

M._tread1D.remapZone = function(field, oldDepthM, newDepthM, removedDepthM, fillTemp)
    local n = #field
    local result = {}
    local oldDepth = math.max(finiteNumber(oldDepthM, 0.001), 1e-6)
    local newDepth = math.max(finiteNumber(newDepthM, oldDepth), 1e-6)
    local shift = math.max(finiteNumber(removedDepthM, 0), 0)
    for j = 1, n do
        local xNew = (j - 0.5) * newDepth / n
        result[j] = M._tread1D.sampleField(field, xNew + shift, oldDepth, fillTemp)
    end
    return result
end

M._tread1D.deriveTemps = function(data, physical)
    if type(data)~="table" or type(data.tread_field)~="table" then return end
    M._tread1D.ensureAdaptiveField(data,physical)
    local nominal=math.max(finiteNumber(physical and physical.treadDepthM,0.006),0.001)
    local decay=math.max(finiteNumber(physical and physical.gripDepthDecayM,M._tread1D.gripDepthDecayM),0.0001)
    data.surface_temp=type(data.surface_temp)=="table" and data.surface_temp or {}; data.temp=type(data.temp)=="table" and data.temp or {ENV_TEMP,ENV_TEMP,ENV_TEMP,ENV_TEMP}; data.tread_bulk_temp=type(data.tread_bulk_temp)=="table" and data.tread_bulk_temp or {}
    local material=M._physicalThermal.getEffectiveTreadMaterial and M._physicalThermal.getEffectiveTreadMaterial(nil) or nil
    local rho=finiteNumber(material and material.density,finiteNumber(physical and physical.rubberDensity,M._physicalThermal.rubberDensity)); local cp=finiteNumber(material and material.cp,finiteNumber(physical and physical.rubberCp,M._physicalThermal.rubberCp))
    data._deriveZoneGeomScratch=type(data._deriveZoneGeomScratch)=="table" and data._deriveZoneGeomScratch or {{},{},{}}
    for z=1,3 do
        local field=data.tread_field[z]; local zg=M._tread1D.buildZoneCellGeometry(data,physical,z,1,rho,cp,data._deriveZoneGeomScratch[z])
        local weightedT,weightSum,bulkE,bulkC=0,0,0,0
        for j=1,zg.activeCount do
            local T=finiteNumber(field[j],ENV_TEMP); local w=M._tread1D.getGripDepthWeightFromGeometry(zg,j,decay)
            weightedT=weightedT+T*w; weightSum=weightSum+w; bulkE=bulkE+T*zg.capacityJPerK[j]; bulkC=bulkC+zg.capacityJPerK[j]
        end
        data.surface_temp[z]=finiteNumber(data.surface_boundary_temp and data.surface_boundary_temp[z],finiteNumber(field[1],ENV_TEMP))
        data.temp[z]=weightSum>0 and weightedT/weightSum or finiteNumber(field[1],ENV_TEMP)
        data.tread_bulk_temp[z]=bulkC>0 and bulkE/bulkC or finiteNumber(field[zg.activeCount],ENV_TEMP)
    end
end

M._repeatedTestThermalCap.applyCaps = function()
    if not M._repeatedTestThermalCap.enabled then return end
    for _, data in pairs(tyreData or {}) do
        if type(data) == "table" and type(data.temp) == "table" then
            local working = math.max(finiteNumber(data.working_temp, 60), ENV_TEMP - 10)
            local treadCap = math.max(working * M._repeatedTestThermalCap.bulkTreadMaxWorkingFactor, ENV_TEMP - 10)
            if type(data.tread_field) == "table" then
                local freeCells = clamp(math.floor(finiteNumber(M._tread1D.uncappedRoadSideCells, 3)), 0, M._tread1D.cells)
                for zone = 1, 3 do
                    local field = data.tread_field[zone]
                    if type(field) == "table" then
                        for j = freeCells + 1, #field do
                            field[j] = math.min(finiteNumber(field[j], working), treadCap)
                        end
                    end
                end
            else
                for zone = 1, 3 do
                    data.temp[zone] = math.min(finiteNumber(data.temp[zone], working), treadCap)
                end
            end
            data.temp[4] = math.min(finiteNumber(data.temp[4], working), working)
            data.air_temp = math.min(finiteNumber(data.air_temp, ENV_TEMP), working)
        end
    end
end

local function normaliseName(value)
    value = string.lower(tostring(value or ""))
    value = value:gsub("[_%-]+", " ")
    value = value:gsub("%s+", " ")
    return value
end

local function classifyTyreProfile(internalName, displayName)
    local text = normaliseName((internalName or "") .. " " .. (displayName or ""))

    if text:find("rally", 1, true) then
        if text:find("asphalt", 1, true) or text:find("tarmac", 1, true)
            or text:find("18x", 1, true) or text:find("r18", 1, true) then
            return TYRE_PROFILES.rally_asphalt
        end
        return TYRE_PROFILES.rally_gravel
    end
    if text:find("tarmac", 1, true) or text:find("asphalt rally", 1, true) then
        return TYRE_PROFILES.rally_asphalt
    end
    if text:find("gravel", 1, true) and
       (text:find("tire", 1, true) or text:find("tyre", 1, true)) then
        return TYRE_PROFILES.rally_gravel
    end

    if text:find("drift", 1, true) or text:find("skid", 1, true) or text:find("burnout", 1, true) then
        return TYRE_PROFILES.drift
    end
    if text:find("sport_plus", 1, true) or text:find("sport plus", 1, true) or
       text:find("psc2", 1, true) or
       text:find("pilot sport cup", 1, true) or text:find("semi slick", 1, true) or
       text:find("semi-slick", 1, true) or text:find("semi race", 1, true) or
       text:find("trackday", 1, true) or text:find("track day", 1, true) then
        return TYRE_PROFILES.semi_slick
    end
    if text:find("sport", 1, true) or text:find("performance", 1, true) then
        return TYRE_PROFILES.sport
    end
    if text:find("race", 1, true) or text:find("racing", 1, true) or
       text:find("slick", 1, true) or text:find("competition", 1, true) or
       text:find("formula", 1, true) or text:find("gt3", 1, true) or
       text:find("gt4", 1, true) or text:find("drag", 1, true) then
        return TYRE_PROFILES.race
    end
    return TYRE_PROFILES.standard
end

local function partDisplayName(partData, fallback)
    if type(partData) == "table" then
        if type(partData.information) == "table" then
            local name = partData.information.name or partData.information.description
            if type(name) == "string" and name ~= "" then return name end
        end
        for _, key in ipairs({ "displayName", "partName", "name", "description" }) do
            local value = partData[key]
            if type(value) == "string" and value ~= "" then return value end
        end
    end
    return tostring(fallback or "Unknown tyre")
end

local function partSearchText(partName, partData, slotName)
    local values = { tostring(partName or ""), tostring(slotName or "") }
    if type(partData) == "table" then
        for _, key in ipairs({ "slotType", "partName", "internalName", "name", "displayName", "description" }) do
            if type(partData[key]) == "string" then table.insert(values, partData[key]) end
        end
        if type(partData.information) == "table" then
            for _, key in ipairs({ "name", "description", "type" }) do
                if type(partData.information[key]) == "string" then
                    table.insert(values, partData.information[key])
                end
            end
        end
    end
    return table.concat(values, " ")
end

local function axleHintFromWheelName(wheelName)
    local name = string.upper(tostring(wheelName or ""))
    if name:sub(1, 1) == "F" then return "front" end
    if name:sub(1, 1) == "R" then return "rear" end
    return ""
end

local function isTyreCandidate(partName, partData, slotName)
    local text = normaliseName(partSearchText(partName, partData, slotName))
    return text:find("tire", 1, true) ~= nil or text:find("tyre", 1, true) ~= nil
end

local function findActivePartData(activeParts, partName)
    if type(activeParts) ~= "table" or type(partName) ~= "string" then return nil end
    if activeParts[partName] ~= nil then return activeParts[partName] end
    local target = normaliseName(partName)
    for key, partData in pairs(activeParts) do
        local resolvedName = type(key) == "string" and key or
            (type(partData) == "table" and (partData.partName or partData.internalName or partData.name))
        if normaliseName(resolvedName) == target then return partData end
    end
    return nil
end

local function tyreCandidateAxleHint(partName, partData, slotName)
    local name = normaliseName(partName)
    local slot = normaliseName(slotName)
    local display = normaliseName(partDisplayName(partData, partName))
    local text = " " .. name .. " " .. slot .. " " .. display .. " "

    local front = display:find("front", 1, true) ~= nil or
        text:find("tire f ", 1, true) ~= nil or text:find("tyre f ", 1, true) ~= nil or
        text:find("tire front", 1, true) ~= nil or text:find("tyre front", 1, true) ~= nil
    local rear = display:find("rear", 1, true) ~= nil or
        text:find("tire r ", 1, true) ~= nil or text:find("tyre r ", 1, true) ~= nil or
        text:find("tire rear", 1, true) ~= nil or text:find("tyre rear", 1, true) ~= nil

    if front and not rear then return "front" end
    if rear and not front then return "rear" end
    return ""
end

local function scoreTyrePartCandidate(partName, partData, slotName, origin, wheelName, source)
    if not isTyreCandidate(partName, partData, slotName) then return -100000 end

    local name = normaliseName(partName)
    local slot = normaliseName(slotName)
    local score = 0
    local originNorm = normaliseName(origin)
    local axle = axleHintFromWheelName(wheelName)
    local display = normaliseName(partDisplayName(partData, partName))
    local searchText = normaliseName(partSearchText(partName, partData, slotName))
    local candidateAxle = tyreCandidateAxleHint(partName, partData, slotName)

    if axle ~= "" and candidateAxle ~= "" then
        if axle == candidateAxle then score = score + 6000
        else score = score - 12000 end
    end

    if source == "chosenParts" then score = score + 30 end

    if originNorm ~= "" then
        if name == originNorm or slot == originNorm then score = score + 20000 end
        local tireOrigin = normaliseName(tostring(origin):gsub("wheeldata", "tire"))
        local tyreOrigin = normaliseName(tostring(origin):gsub("wheeldata", "tyre"))
        if name == tireOrigin or name == tyreOrigin or slot == tireOrigin or slot == tyreOrigin then
            score = score + 10000
        end

        for token in originNorm:gmatch("[%w]+") do
            if #token >= 3 and token ~= "wheeldata" then
                if name:find(token, 1, true) then score = score + 8 end
                if slot:find(token, 1, true) then score = score + 6 end
            end
        end
    end

    if axle == "front" then
        if name:find(" front", 1, true) or slot:find(" front", 1, true) or
           display:find("front", 1, true) or name:match(" f$") or slot:match(" f$") then score = score + 60 end
        if name:find(" rear", 1, true) or slot:find(" rear", 1, true) or
           display:find("rear", 1, true) or name:match(" r$") or slot:match(" r$") then score = score - 30 end
    elseif axle == "rear" then
        if name:find(" rear", 1, true) or slot:find(" rear", 1, true) or
           display:find("rear", 1, true) or name:match(" r$") or slot:match(" r$") then score = score + 60 end
        if name:find(" front", 1, true) or slot:find(" front", 1, true) or
           display:find("front", 1, true) or name:match(" f$") or slot:match(" f$") then score = score - 30 end
    end

    if searchText:find("sport", 1, true) or searchText:find("race", 1, true) or
       searchText:find("slick", 1, true) or searchText:find("rally", 1, true) or
       searchText:find("drift", 1, true) then
        score = score + 2
    end

    return score
end

local function findTyrePartForWheel(wheelID, wheelDef, wheelRotator)
    local vehicleData = (v and v.data) or {}
    local activeParts = vehicleData.activeParts or {}
    local chosenParts = vehicleData.chosenParts or {}
    local partConfig = (obj and obj.partConfig) or {}
    if type(partConfig) ~= "table" then partConfig = {} end
    local configuredParts = type(partConfig.parts) == "table" and partConfig.parts or partConfig
    local origin = (wheelRotator and wheelRotator.partOrigin) or (wheelDef and wheelDef.partOrigin) or ""
    local wheelName = (wheelRotator and wheelRotator.name) or (wheelDef and wheelDef.name) or tostring(wheelID)

    local candidates = {}
    local candidateKeys = {}
    local function addCandidate(partName, partData, slotName, source)
        if type(partName) ~= "string" or partName == "" then return end
        if not isTyreCandidate(partName, partData, slotName) then return end
        local key = normaliseName(partName) .. "|" .. normaliseName(slotName)
        if candidateKeys[key] then return end
        candidateKeys[key] = true
        table.insert(candidates, {
            partName = partName,
            partData = partData,
            slotName = slotName or "",
            source = source or "activeParts"
        })
    end

    for slotName, chosenPartName in pairs(chosenParts) do
        if type(chosenPartName) == "string" and chosenPartName ~= "" then
            addCandidate(chosenPartName, findActivePartData(activeParts, chosenPartName), slotName, "chosenParts")
        end
    end

    if type(configuredParts) == "table" then
        for slotName, configuredPartName in pairs(configuredParts) do
            if type(configuredPartName) == "string" and configuredPartName ~= "" then
                addCandidate(configuredPartName, findActivePartData(activeParts, configuredPartName), slotName, "partConfig")
            end
        end
    end

    for key, partData in pairs(activeParts) do
        local partName = type(key) == "string" and key or
            (type(partData) == "table" and (partData.partName or partData.internalName or partData.name))
        addCandidate(partName, partData, type(partData) == "table" and partData.slotType or "", "activeParts")
    end

    local taggedCandidate, taggedScore = nil, -100000
    for _, candidate in ipairs(candidates) do
        local taggedText = normaliseName(partSearchText(
            candidate.partName, candidate.partData, candidate.slotName))
        local tagPriority = 0
        if taggedText:find("rally", 1, true) or taggedText:find("tarmac", 1, true)
            or taggedText:find("gravel", 1, true) then
            tagPriority = 5
        elseif taggedText:find("drift", 1, true) then
            tagPriority = 4
        elseif taggedText:find("race", 1, true) or taggedText:find("racing", 1, true)
            or taggedText:find("slick", 1, true) or taggedText:find("competition", 1, true) then
            tagPriority = 3
        elseif taggedText:find("sport", 1, true) or taggedText:find("performance", 1, true)
            or taggedText:find("trackday", 1, true) or taggedText:find("track day", 1, true) then
            tagPriority = 2
        end
        if tagPriority > 0 then
            local taggedCandidateScore = scoreTyrePartCandidate(
                candidate.partName, candidate.partData, candidate.slotName,
                origin, wheelName, candidate.source) + tagPriority * 1000
            if candidate.source == "chosenParts" then taggedCandidateScore = taggedCandidateScore + 500 end
            if candidate.source == "partConfig" then taggedCandidateScore = taggedCandidateScore + 350 end
            if taggedCandidateScore > taggedScore then
                taggedCandidate, taggedScore = candidate, taggedCandidateScore
            end
        end
    end
    if taggedCandidate and taggedScore > 0 then
        return taggedCandidate.partName,
            partDisplayName(taggedCandidate.partData, taggedCandidate.partName),
            partSearchText(taggedCandidate.partName, taggedCandidate.partData, taggedCandidate.slotName),
            taggedCandidate.source .. "/compound"
    end

    local exactNames = { tostring(origin or "") }
    if normaliseName(origin):find("wheeldata", 1, true) then
        local tireMapped = tostring(origin):gsub("wheeldata", "tire")
        local tyreMapped = tostring(origin):gsub("wheeldata", "tyre")
        table.insert(exactNames, tireMapped)
        table.insert(exactNames, tyreMapped)
    end
    for _, exactName in ipairs(exactNames) do
        local exactNorm = normaliseName(exactName)
        if exactNorm ~= "" then
            for _, candidate in ipairs(candidates) do
                if normaliseName(candidate.partName) == exactNorm or normaliseName(candidate.slotName) == exactNorm then
                    local displayName = partDisplayName(candidate.partData, candidate.partName)
                    return candidate.partName, displayName,
                        partSearchText(candidate.partName, candidate.partData, candidate.slotName),
                        candidate.source .. "/exact"
                end
            end
        end
    end

    local bestCandidate, bestScore = nil, -100000
    for _, candidate in ipairs(candidates) do
        local score = scoreTyrePartCandidate(candidate.partName, candidate.partData, candidate.slotName,
            origin, wheelName, candidate.source)
        if score > bestScore then
            bestCandidate, bestScore = candidate, score
        end
    end

    if bestCandidate and (bestScore > 0 or #candidates == 1) then
        return bestCandidate.partName,
            partDisplayName(bestCandidate.partData, bestCandidate.partName),
            partSearchText(bestCandidate.partName, bestCandidate.partData, bestCandidate.slotName),
            bestCandidate.source
    end

    local wheelTextValues = { origin, wheelName }
    for _, sourceTable in ipairs({ wheelRotator, wheelDef }) do
        if type(sourceTable) == "table" then
            for _, key in ipairs({ "tireName", "tyreName", "tirePart", "tyrePart", "partName", "slotType" }) do
                if type(sourceTable[key]) == "string" then table.insert(wheelTextValues, sourceTable[key]) end
            end
        end
    end
    local wheelText = table.concat(wheelTextValues, " ")
    if normaliseName(wheelText):find("tire", 1, true) or normaliseName(wheelText):find("tyre", 1, true) then
        return tostring(origin ~= "" and origin or wheelName), wheelText, wheelText, "wheelData"
    end

    return "unknown_tyre", "Unknown tyre", "", "fallback"
end

local function detectTyreProfiles()
    local previousSignature = RT.tyreProfileDetectionSignature
    local newProfiles = {}
    local signatureParts = {}
    local fallbackCount = 0

    for wheelID, wheelRotator in pairs((wheels and wheels.wheelRotators) or {}) do
        local wheelDef = v and v.data and v.data.wheels and v.data.wheels[wheelID]
        local internalName, displayName, searchText, source = findTyrePartForWheel(wheelID, wheelDef, wheelRotator)
        local profile = classifyTyreProfile(internalName, tostring(displayName or "") .. " " .. tostring(searchText or ""))
        if source == "fallback" then fallbackCount = fallbackCount + 1 end
        newProfiles[wheelID] = {
            profile = profile,
            internalName = internalName,
            displayName = displayName,
            source = source,
            searchText = searchText
        }
        table.insert(signatureParts, tostring(wheelID) .. ":" .. tostring(internalName) .. ":" .. profile.id .. ":" .. source)
    end

    table.sort(signatureParts)
    RT.tyreProfileDetectionSignature = table.concat(signatureParts, "|")
    RT.wheelTyreProfiles = newProfiles
    RT.tyreProfileFallbackCount = fallbackCount
    RT.tyreProfileDetectionRevision = RT.tyreProfileDetectionRevision + 1
    refreshThermalPreset(false)

    return RT.tyreProfileDetectionSignature ~= previousSignature, fallbackCount, #signatureParts
end


-- LIVE TREAD-BEAM STARTUP POP FAIL-SAFE ---------------------------------------
-- Why this exists:
-- A few tyre JBeams can become unstable when KTS' live tread-beam stiffness owns
-- their tread springs.  If that construction explodes/deflates immediately after
-- spawn, repeatedly applying the same live stiffness on every reload can trap the
-- user in a pop -> reset -> pop loop.
--
-- Behaviour:
--   * Observe ONLY the first 5.0 s after vehicle init/reset.
--   * Learn ONLY a NEW false->true deflation/broken transition. A tyre which was
--     already flat when this guard armed is not learned.
--   * Only tyres classified by KTS as profile.id == "race" are eligible for
--     collection or blacklist enforcement. Sport, Semi-Slick, Standard, Drift and
--     Rally profiles are intentionally ignored by this fail-safe.
--   * Key the blacklist by KTS' resolved tyre part internalName. Never store
--     "unknown_tyre": a generic/fallback ID would blacklist unrelated tyres.
--   * Persist learned race-tyre IDs under settings/kagoni_tyre_calibration so the
--     database grows across sessions.
--   * When a learned race tyre appears again, live physical tread stiffness is
--     forced OFF before its normal actuator can run.
--   * On the first new startup-pop detection, write the database FIRST, then ask
--     GELua for an Insert-style vehicle reset/recovery once. The reset lifecycle
--     sees the saved tyre ID and keeps live stiffness disabled.
--   * Discovery/reset is restricted to the currently seated player vehicle.
--     Known blacklist IDs are still honoured in any vehicle VM, which matters if
--     the optional all-traffic KTS simulation mode is enabled.
--
-- This guard owns only the live physical-stiffness enable state. It does NOT alter
-- the thermal model, grip model, wear, pressure, tyre classification, spring maps,
-- damping maps, geometry observer, or stiffness calibration values.
M._liveStiffnessPopGuard = M._liveStiffnessPopGuard or {
    schema = 1,
    path = "settings/kagoni_tyre_calibration/KTS_live_stiffness_tyre_blacklist.json",
    startupWindowS = 5.0,
    loaded = false,
    entries = {},
    armed = false,
    ageS = 0,
    baselineDeflated = {},
    pendingPoppedWheel = {},
    reloadRequested = false,
    disabledByBlacklist = false,
    lastMatchedTyreId = nil,
}

M._liveStiffnessPopGuard.normalizeTyreId = function(value)
    local id = tostring(value or "")
    id = string.gsub(id, "^%s+", "")
    id = string.gsub(id, "%s+$", "")
    if id == "" then return nil end
    local lower = string.lower(id)
    if lower == "unknown_tyre" or lower == "unknown tyre" or lower == "unknown" then
        return nil
    end
    return lower, id
end

M._liveStiffnessPopGuard.timestamp = function()
    local ok, stamp = pcall(function()
        if os and os.date then return os.date("!%Y-%m-%dT%H:%M:%SZ") end
        return nil
    end)
    return ok and stamp or nil
end

M._liveStiffnessPopGuard.load = function(forceDisk)
    local self = M._liveStiffnessPopGuard
    if self.loaded and forceDisk ~= true then return true end

    local loadedEntries = {}
    local ok, payload = pcall(function() return jsonReadFile(self.path) end)
    if ok and type(payload) == "table" and type(payload.entries) == "table" then
        for key, entry in pairs(payload.entries) do
            local normalized, original = self.normalizeTyreId(
                type(entry) == "table" and entry.internal_name or key
            )
            if normalized then
                if type(entry) ~= "table" then entry = {} end
                loadedEntries[normalized] = {
                    internal_name = tostring(entry.internal_name or original),
                    first_detected_utc = entry.first_detected_utc,
                    last_detected_utc = entry.last_detected_utc,
                    detections = math.max(tonumber(entry.detections) or 1, 1),
                    reason = tostring(entry.reason or "startup-live-stiffness-pop"),
                    profile_id = entry.profile_id and tostring(entry.profile_id) or nil,
                    last_wheel = entry.last_wheel and tostring(entry.last_wheel) or nil,
                }
            end
        end
    end

    self.entries = loadedEntries
    self.loaded = true
    return true
end

M._liveStiffnessPopGuard.save = function()
    local self = M._liveStiffnessPopGuard
    if FS and FS.directoryCreate then
        pcall(function() FS:directoryCreate("settings/kagoni_tyre_calibration", true) end)
    end
    local payload = {
        schema = self.schema,
        startup_window_s = self.startupWindowS,
        description = "Race-tyre part IDs auto-disabled for KTS live tread-beam stiffness after a startup pop.",
        entries = self.entries,
    }
    local ok, result = pcall(function() return jsonWriteFile(self.path, payload, true, 7) end)
    if not ok or result == false then
        log("W", "luukstyrethermalsandwear",
            "Live stiffness pop-guard database save failed: " .. tostring(result))
        return false
    end
    return true
end

M._liveStiffnessPopGuard.getTyreId = function(wheelID)
    local detected = RT and RT.wheelTyreProfiles and
        (RT.wheelTyreProfiles[wheelID] or RT.wheelTyreProfiles[tonumber(wheelID)]) or nil
    local raw = detected and detected.internalName or nil

    -- During very early spawn the profile detector can still be on fallback.
    -- tyreData may already have the resolved identity, so use it as a second source.
    if raw == nil and tyreData then
        local data = tyreData[wheelID] or tyreData[tonumber(wheelID)]
        raw = data and data.tyre_internal_name or nil
    end

    local normalized, original = M._liveStiffnessPopGuard.normalizeTyreId(raw)
    return normalized, original
end

M._liveStiffnessPopGuard.isRaceTyre = function(wheelID)
    local detected = RT and RT.wheelTyreProfiles and
        (RT.wheelTyreProfiles[wheelID] or RT.wheelTyreProfiles[tonumber(wheelID)]) or nil
    local profile = detected and detected.profile or nil

    -- Use KTS' existing tyre classifier as the sole eligibility source. Do not infer
    -- race status from the internalName here: that would duplicate classification
    -- rules and could accidentally blacklist road-legal Semi-Slick/Sport tyres.
    return profile ~= nil and tostring(profile.id or "") == "race"
end

M._liveStiffnessPopGuard.getRaceEligibilityState = function()
    local hasRace = false
    local hasResolved = false
    local hasUnresolved = false

    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        local detected = RT and RT.wheelTyreProfiles and
            (RT.wheelTyreProfiles[wheelID] or RT.wheelTyreProfiles[tonumber(wheelID)]) or nil
        local profile = detected and detected.profile or nil

        if profile ~= nil then
            hasResolved = true
            if tostring(profile.id or "") == "race" then
                hasRace = true
            end
        else
            hasUnresolved = true
        end
    end

    return hasRace, hasResolved, hasUnresolved
end

M._liveStiffnessPopGuard.getCurrentRaceTyreIds = function()
    local self = M._liveStiffnessPopGuard
    local result = {}
    local seen = {}

    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if self.isRaceTyre(wheelID) then
            local key, original = self.getTyreId(wheelID)
            if key and not seen[key] then
                seen[key] = true
                result[#result + 1] = {
                    key = key,
                    internalName = original,
                    wheelID = wheelID,
                }
            end
        end
    end
    return result
end

M._liveStiffnessPopGuard.isCurrentRaceTyreBlacklisted = function()
    local self = M._liveStiffnessPopGuard
    self.load(false)

    for _, item in ipairs(self.getCurrentRaceTyreIds()) do
        if self.entries[item.key] then
            return true
        end
    end
    return false
end

M._liveStiffnessPopGuard.setCurrentRaceTyreBlacklisted = function(enabled)
    local self = M._liveStiffnessPopGuard
    self.load(false)

    local current = self.getCurrentRaceTyreIds()
    if #current == 0 then
        -- The manual Experimental control is intentionally race-only, matching the
        -- automatic startup guard. Non-race tyre IDs are never written to this DB.
        return false
    end

    local changed = false
    if enabled == true then
        local now = self.timestamp()
        for _, item in ipairs(current) do
            local previous = self.entries[item.key]
            if not previous then changed = true end
            self.entries[item.key] = {
                internal_name = tostring(item.internalName),
                first_detected_utc = previous and previous.first_detected_utc or now,
                last_detected_utc = now,
                detections = previous and tonumber(previous.detections) or 0,
                reason = previous and tostring(previous.reason or "manual-experimental-blacklist")
                    or "manual-experimental-blacklist",
                profile_id = "race",
                last_wheel = previous and previous.last_wheel or nil,
            }
        end

        -- Manual blacklisting takes effect immediately, but deliberately does NOT
        -- perform an Insert-style reset. The user remains in control of vehicle reset.
        if M._sportPhysicalStiffness then
            M._sportPhysicalStiffness.enabled = false
        end
        self.disabledByBlacklist = true
    else
        -- Unchecking is an explicit user override. It removes the fitted race tyre
        -- ID(s) even when they were originally learned automatically after a pop.
        for _, item in ipairs(current) do
            if self.entries[item.key] ~= nil then
                self.entries[item.key] = nil
                changed = true
            end
        end

        local stillBlocked = self.hasActiveBlacklistedTyre()
        self.disabledByBlacklist = stillBlocked == true
        -- Do not automatically turn live stiffness back ON here. Once the blacklist
        -- is removed, the normal "Live tread physical stiffness" toggle can enable it.
    end

    if changed then self.save() end
    return self.isCurrentRaceTyreBlacklisted()
end

M._liveStiffnessPopGuard.isWheelDeflated = function(wheelID)
    local wheelState = wheels and wheels.wheels and
        (wheels.wheels[wheelID] or wheels.wheels[tonumber(wheelID)]) or nil
    local cached = wheelCache and
        (wheelCache[wheelID] or wheelCache[tonumber(wheelID)]) or nil

    return (wheelState and (wheelState.isTireDeflated == true or wheelState.isBroken == true))
        or (cached and (cached.isTireDeflated == true or cached.isBroken == true))
        or false
end

M._liveStiffnessPopGuard.hasActiveBlacklistedTyre = function()
    local self = M._liveStiffnessPopGuard
    self.load(false)

    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if self.isRaceTyre(wheelID) then
            local key, original = self.getTyreId(wheelID)
            if key and self.entries[key] then
                self.lastMatchedTyreId = original or self.entries[key].internal_name
                return true, self.lastMatchedTyreId
            end
        end
    end
    self.lastMatchedTyreId = nil
    return false, nil
end

M._liveStiffnessPopGuard.applyKnownBlacklist = function()
    local self = M._liveStiffnessPopGuard
    local blocked, tyreId = self.hasActiveBlacklistedTyre()
    if blocked then
        if M._sportPhysicalStiffness then
            M._sportPhysicalStiffness.enabled = false
        end
        self.disabledByBlacklist = true
        log("W", "luukstyrethermalsandwear",
            "Live tread-beam stiffness auto-disabled for blacklisted tyre: " .. tostring(tyreId))
        return true
    end
    self.disabledByBlacklist = false
    return false
end

M._liveStiffnessPopGuard.recordTyre = function(wheelID)
    local self = M._liveStiffnessPopGuard

    -- Collection is race-only. A road/Sport/Semi-Slick/Rally/Drift tyre popping
    -- during startup must never grow this blacklist or disable live stiffness.
    if not self.isRaceTyre(wheelID) then return false end

    local key, original = self.getTyreId(wheelID)
    if not key then return false end

    local now = self.timestamp()
    local wr = wheels and wheels.wheelRotators and
        (wheels.wheelRotators[wheelID] or wheels.wheelRotators[tonumber(wheelID)]) or nil
    local previous = self.entries[key]

    self.entries[key] = {
        internal_name = tostring(original),
        first_detected_utc = previous and previous.first_detected_utc or now,
        last_detected_utc = now,
        detections = (previous and tonumber(previous.detections) or 0) + 1,
        reason = "startup-live-stiffness-pop",
        profile_id = "race",
        last_wheel = tostring(wr and wr.name or wheelID),
    }
    self.lastMatchedTyreId = original
    return true
end

M._liveStiffnessPopGuard.arm = function(reason)
    local self = M._liveStiffnessPopGuard
    self.load(false)
    self.ageS = 0
    self.armed = true
    self.reloadRequested = false
    self.baselineDeflated = {}
    self.pendingPoppedWheel = {}

    -- If KTS has already resolved the fitted tyre profiles and NONE are race tyres,
    -- disable the complete five-second pop detector now. No deflation sampling,
    -- transition tracking or blacklist lookup is needed for a non-race tyre set.
    local hasRace, hasResolved, hasUnresolved = self.getRaceEligibilityState()
    if not hasRace and hasResolved and not hasUnresolved then
        self.armed = false
        return false
    end

    -- A known bad race construction must be disabled immediately after tyre detection,
    -- before the normal live-stiffness update gets its first chance to write beams.
    if self.applyKnownBlacklist() then
        self.armed = false
        return false
    end

    -- Snapshot only eligible race wheels so non-race tyres add zero pop-sampling work.
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if self.isRaceTyre(wheelID) then
            self.baselineDeflated[wheelID] = self.isWheelDeflated(wheelID)
        end
    end
    return true
end

M._liveStiffnessPopGuard.update = function(dt)
    local self = M._liveStiffnessPopGuard
    if not self.armed then return end

    -- Never make an AI/traffic VM reset whichever car the human currently occupies.
    -- Known IDs are still disabled in AI VMs by arm()/applyKnownBlacklist().
    if not (playerInfo and playerInfo.firstPlayerSeated) then return end

    self.ageS = self.ageS + math.max(tonumber(dt) or 0, 0)
    if self.ageS > self.startupWindowS then
        self.armed = false
        return
    end

    -- A tyre profile can be unresolved for a few startup frames. As soon as the
    -- classifier has resolved the fitted set and no race tyre exists, permanently
    -- disarm this startup pass instead of continuing the five-second sampling loop.
    local hasRace, hasResolved, hasUnresolved = self.getRaceEligibilityState()
    if not hasRace and hasResolved and not hasUnresolved then
        self.armed = false
        self.baselineDeflated = {}
        self.pendingPoppedWheel = {}
        return
    end

    -- If profile detection resolved a previously-fallback race ID to an already-known
    -- bad construction during the 5 s window, shut live stiffness down immediately.
    if hasRace and self.applyKnownBlacklist() then
        self.armed = false
        return
    end

    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if self.isRaceTyre(wheelID) then
            local nowDeflated = self.isWheelDeflated(wheelID)
            local wasDeflated = self.baselineDeflated[wheelID]

            if wasDeflated == nil then
                self.baselineDeflated[wheelID] = nowDeflated
            else
                if wasDeflated == false and nowDeflated == true then
                    self.pendingPoppedWheel[wheelID] = true
                end
                self.baselineDeflated[wheelID] = nowDeflated
            end
        end
    end

    local learnedAny = false
    for wheelID, pending in pairs(self.pendingPoppedWheel) do
        if pending then
            local key = self.getTyreId(wheelID)
            local isRace = self.isRaceTyre(wheelID)
            if (not key or not isRace) and RT and tonumber(RT.tyreProfileFallbackCount or 0) > 0 then
                -- One immediate retry is safe here and prevents losing a genuine race-
                -- tyre pop simply because chosenParts/activeParts resolved one frame late.
                detectTyreProfiles()
                key = self.getTyreId(wheelID)
                isRace = self.isRaceTyre(wheelID)
            end
            if key and isRace and self.recordTyre(wheelID) then
                self.pendingPoppedWheel[wheelID] = nil
                learnedAny = true
            end
        end
    end

    if not learnedAny then return end

    -- Stop writes first, persist second, reset third. The ordering is intentional:
    -- the reset lifecycle must be able to read the blacklist immediately.
    if M._sportPhysicalStiffness then
        M._sportPhysicalStiffness.enabled = false
    end
    self.disabledByBlacklist = true
    self.save()
    self.armed = false

    if not self.reloadRequested and obj and obj.queueGameEngineLua then
        self.reloadRequested = true
        log("E", "luukstyrethermalsandwear",
            "Startup tyre pop detected with live tread stiffness; tyre ID saved and current vehicle will Insert-style reset with live stiffness OFF: "
            .. tostring(self.lastMatchedTyreId))
        obj:queueGameEngineLua("if be then be:resetVehicle(0) end")
    end
end
-- END LIVE TREAD-BEAM STARTUP POP FAIL-SAFE -----------------------------------

M._rallyCompounds.getSurface = function(surfaceId)
    local cfg = M._rallyCompounds or {}
    local surfaces = cfg.surfaces or {}
    surfaceId = string.lower(tostring(surfaceId or cfg.selectedSurface or "asphalt"))
    return surfaces[surfaceId] or surfaces.asphalt
end

M._rallyCompounds.getSelectedSurface = function()
    return M._rallyCompounds.getSurface(M._rallyCompounds.selectedSurface)
end

M._rallyCompounds.getVariantForProfile = function(profile)
    local profileId = profile and tostring(profile.id or "") or ""
    local surfaceId = profileId == "rally_gravel" and "gravel" or "asphalt"
    local surface = M._rallyCompounds.getSurface(surfaceId)
    local variants = surface and surface.variants or {}
    return variants[M._rallyCompounds.selectedCompound or "medium"] or variants.medium, surface
end

M._rallyCompounds.getSelected = function()
    local surface = M._rallyCompounds.getSelectedSurface()
    local variants = surface and surface.variants or {}
    return variants[M._rallyCompounds.selectedCompound or "medium"] or variants.medium, surface
end

M._rallyCompounds.applyProfile = function(profile)
    if not profile or (profile.id ~= "rally_asphalt" and profile.id ~= "rally_gravel") then return profile end
    local variant = M._rallyCompounds.getVariantForProfile(profile)
    return variant and variant.profile or profile
end

M._rallyCompounds.getRoadGripMultiplier = function(wheelID, hardRoadSurface)
    if hardRoadSurface ~= true then return 1.0 end
    local detected = RT.wheelTyreProfiles and RT.wheelTyreProfiles[wheelID] or nil
    local baseProfile = detected and detected.profile or nil
    if MANUAL_TYRE_PROFILE == "rally" then
        local variant, surface = M._rallyCompounds.getSelected()
        return clamp(finiteNumber(surface and surface.roadPeakMultiplier, 1.0)
            * finiteNumber(variant and variant.gripMultiplier, 1.0), 0.80, 1.10)
    end
    if MANUAL_TYRE_PROFILE == "auto" and baseProfile
        and (baseProfile.id == "rally_asphalt" or baseProfile.id == "rally_gravel") then
        local variant, surface = M._rallyCompounds.getVariantForProfile(baseProfile)
        return clamp(finiteNumber(surface and surface.roadPeakMultiplier, 1.0)
            * finiteNumber(variant and variant.gripMultiplier, 1.0), 0.80, 1.10)
    end
    return 1.0
end

M._rallyCompounds.getWearMultiplier = function(profile)
    if not profile or (profile.id ~= "rally_asphalt" and profile.id ~= "rally_gravel") then return 1.0 end
    local variant = M._rallyCompounds.getVariantForProfile(profile)
    return clamp(finiteNumber(variant and variant.wearMultiplier, 1.0), 0.40, 2.00)
end

M._rallyCompounds.setSurfacePreset = function(surfaceId)
    surfaceId = string.lower(tostring(surfaceId or "asphalt"))
    if not (M._rallyCompounds.surfaces or {})[surfaceId] then return false end

    local depthHealthBefore = {}
    if MANUAL_TYRE_PROFILE == "rally" then
        local oldVariant = M._rallyCompounds.getSelected()
        local oldPhysical = M._physicalThermal.getPhysicalProfile(oldVariant and oldVariant.profile)
        for wheelID, data in pairs(tyreData or {}) do
            depthHealthBefore[wheelID] = M._tread1D.capturePresetDepthHealth(data, oldPhysical)
        end
    end

    M._rallyCompounds.selectedSurface = surfaceId
    wheelFlashGripState = {}

    if MANUAL_TYRE_PROFILE == "rally" then
        local newVariant = M._rallyCompounds.getSelected()
        local newPhysical = M._physicalThermal.getPhysicalProfile(newVariant and newVariant.profile)
        for wheelID, data in pairs(tyreData or {}) do
            M._tread1D.applyPresetDepthHealth(data, depthHealthBefore[wheelID], newPhysical)
        end
    end
    return surfaceId
end

M._rallyCompounds.getSurfacePreset = function()
    return (M._rallyCompounds and M._rallyCompounds.selectedSurface) or "asphalt"
end

M._rallyCompounds.setCompoundPreset = function(compoundId)
    compoundId = string.lower(tostring(compoundId or "medium"))
    local surface = M._rallyCompounds.getSelectedSurface()
    if not (surface and surface.variants and surface.variants[compoundId]) then return false end
    M._rallyCompounds.selectedCompound = compoundId
    wheelFlashGripState = {}
    return compoundId
end

M._rallyCompounds.getCompoundPreset = function()
    return (M._rallyCompounds and M._rallyCompounds.selectedCompound) or "medium"
end

M._slickCompounds.getSelected = function()
    local cfg = M._slickCompounds or {}
    local variants = cfg.variants or {}
    return variants[cfg.selected or "medium"] or variants.medium
end

M._slickCompounds.applyProfile = function(profile)
    if not profile or profile.id ~= "race" then return profile end
    local compound = M._slickCompounds.getSelected()
    return compound and compound.profile or profile
end

M._slickCompounds.getFullSlideRatio = function(tempC)
    local cfg = M._slickCompounds or {}
    local compound = M._slickCompounds.getSelected()
    local points = compound and compound.fullSlideRatioTempPoints or nil
    local warm = clamp(finiteNumber(cfg.warmFullSlideAnchor, 0.86), 0.05, 1.50)
    if type(points) ~= "table" or #points < 1 then return warm end
    local t = finiteNumber(tempC, ENV_TEMP)
    if t <= finiteNumber(points[1][1], 0) then return finiteNumber(points[1][2], warm) end
    for i = 2, #points do
        local t1, v1 = finiteNumber(points[i - 1][1], 0), finiteNumber(points[i - 1][2], warm)
        local t2, v2 = finiteNumber(points[i][1], t1 + 1), finiteNumber(points[i][2], v1)
        if t <= t2 then
            return lerp(v1, v2, clamp((t - t1) / math.max(t2 - t1, 0.000001), 0, 1))
        end
    end
    return finiteNumber(points[#points][2], warm)
end

M._slickCompounds.getColdRelativeGripScale = function(profile, tempC)
    if not profile or profile.id ~= "race" then return 1.0 end
    local cfg = M._slickCompounds or {}
    local compound = M._slickCompounds.getSelected()
    local cold = clamp(finiteNumber(cfg.coldGripRelativeScale, 0.90), 0.50, 1.00)
    local t0 = finiteNumber(cfg.coldGripFullPenaltyBelowC, 20.0)
    local tw = math.max(finiteNumber(profile.workingTemp, 100.0), t0 + 1.0)
    local t = finiteNumber(tempC, ENV_TEMP)

    local baseCold
    if t <= t0 then
        baseCold = cold
    elseif t >= tw then
        baseCold = 1.0
    else
        local u = clamp((t - t0) / (tw - t0), 0.0, 1.0)
        local smooth = u * u * (3.0 - 2.0 * u)
        baseCold = cold + (1.0 - cold) * smooth
    end

    local knee = finiteNumber(compound and compound.dynamicGlassKneeC, -100.0)
    local span = math.max(finiteNumber(cfg.glassTransitionBlendSpanC, 20.0), 1.0)
    local minScale = clamp(finiteNumber(compound and compound.glassPeakMinScale, 1.0), 0.40, 1.0)
    local glassScale = 1.0
    if t < knee then
        local u = clamp((t - (knee - span)) / span, 0.0, 1.0)
        local smooth = u * u * (3.0 - 2.0 * u)
        glassScale = minScale + (1.0 - minScale) * smooth
    end
    return clamp(baseCold * glassScale, 0.20, 1.0)
end

M._slickCompounds.getGripMultiplier = function(wheelID)
    local detected = RT.wheelTyreProfiles and RT.wheelTyreProfiles[wheelID] or nil
    local baseProfile = detected and detected.profile or nil
    if MANUAL_TYRE_PROFILE == "race" or (MANUAL_TYRE_PROFILE == "auto" and baseProfile and baseProfile.id == "race") then
        local compound = M._slickCompounds.getSelected()
        return clamp(finiteNumber(compound and compound.gripMultiplier, 1.0), 0.90, 1.10)
    end
    return 1.0
end

M._slickCompounds.getWearMultiplier = function(profile)
    if profile and (profile.id == "rally_asphalt" or profile.id == "rally_gravel") then
        return M._rallyCompounds.getWearMultiplier(profile)
    end
    if not profile or profile.id ~= "race" then return 1.0 end
    local compound = M._slickCompounds.getSelected()
    return clamp(finiteNumber(compound and compound.wearMultiplier, 1.0), 0.40, 2.00)
end

M._slickCompounds.setPreset = function(compoundId)
    compoundId = string.lower(tostring(compoundId or "medium"))
    local variants = M._slickCompounds and M._slickCompounds.variants or {}
    if not variants[compoundId] then return false end
    M._slickCompounds.selected = compoundId
    wheelFlashGripState = {}
    return compoundId
end

M._slickCompounds.getPreset = function()
    return (M._slickCompounds and M._slickCompounds.selected) or "medium"
end

local function getWheelTyreProfile(wheelID)
    local detected = RT.wheelTyreProfiles[wheelID] or {
        profile = TYRE_PROFILES.standard,
        internalName = "unknown_tyre",
        displayName = "Unknown tyre",
        source = "fallback"
    }

    if MANUAL_TYRE_PROFILE == "rally" then
        local rallyProfile = M._rallyCompounds.getSelected()
        return {
            profile = rallyProfile and rallyProfile.profile or TYRE_PROFILES.rally_asphalt,
            internalName = detected.internalName,
            displayName = detected.displayName,
            source = "manual"
        }
    end

    local forcedProfile = TYRE_PROFILES[MANUAL_TYRE_PROFILE]
    if MANUAL_TYRE_PROFILE ~= "auto" and forcedProfile then
        return {
            profile = M._slickCompounds.applyProfile(forcedProfile),
            internalName = detected.internalName,
            displayName = detected.displayName,
            source = "manual"
        }
    end

    if detected.profile and detected.profile.id == "race" then
        return {
            profile = M._slickCompounds.applyProfile(detected.profile),
            internalName = detected.internalName,
            displayName = detected.displayName,
            source = detected.source
        }
    end
    if detected.profile and (detected.profile.id == "rally_asphalt" or detected.profile.id == "rally_gravel") then
        return {
            profile = M._rallyCompounds.applyProfile(detected.profile),
            internalName = detected.internalName,
            displayName = detected.displayName,
            source = detected.source
        }
    end
    return detected
end

local getWheelDefForBrush

local function parseMetricTyreSizeText(value)
    local text = string.lower(tostring(value or ""))
    local w, a, rim = text:match("(%d%d%d)_(%d%d)_(%d%d)")
    if not w then w, a, rim = text:match("(%d%d%d)%-(%d%d)%-(%d%d)") end
    if not w then w, a, rim = text:match("(%d%d%d)%s*/%s*(%d%d)%s*r%s*(%d%d)") end
    w, a, rim = tonumber(w), tonumber(a), tonumber(rim)
    if not w or not a or not rim then return nil end
    if w < 100 or w > 450 or a < 20 or a > 95 or rim < 10 or rim > 26 then return nil end
    local widthM = w / 1000
    local aspect = a / 100
    local rimRadiusM = rim * 0.0254 * 0.5
    return {
        sectionWidthM = widthM,
        aspectRatio = aspect,
        rimDiameterIn = rim,
        rimRadiusM = rimRadiusM,
        nominalOuterRadiusM = rimRadiusM + widthM * aspect
    }
end

local function getNominalMetricTyreGeometry(wheelID)
    local rawDetected = RT.wheelTyreProfiles and RT.wheelTyreProfiles[wheelID] or nil
    local resolved = getWheelTyreProfile(wheelID)
    local candidates = {
        resolved and resolved.internalName, resolved and resolved.displayName,
        rawDetected and rawDetected.internalName, rawDetected and rawDetected.displayName,
        rawDetected and rawDetected.searchText
    }
    for _, value in ipairs(candidates) do
        local parsed = parseMetricTyreSizeText(value)
        if parsed then
            local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
            local wd = getWheelDefForBrush(wheelID)
            local runtimeRadius = finiteNumber(wr and wr.radius, finiteNumber(wd and wd.radius, nil))
            if runtimeRadius then
                local delta = math.abs(runtimeRadius - parsed.nominalOuterRadiusM)
                local tolerance = math.max(0.025, runtimeRadius * 0.08)
                if delta > tolerance then
                else
                    parsed.runtimeRadiusDeltaM = runtimeRadius - parsed.nominalOuterRadiusM
                    parsed.source = "tyre-part-metric-size"
                    return parsed
                end
            else
                parsed.runtimeRadiusDeltaM = 0
                parsed.source = "tyre-part-metric-size"
                return parsed
            end
        end
    end
    return nil
end

local function normalizeTyrePressureOverrideKey(internalName)
    return string.lower(tostring(internalName or ""))
end

local function getTyreStructuralReferencePressurePsi(wheelID, profile)
    profile = profile or TYRE_PROFILES.standard
    local cfg = M._pressureWheelBrush or {}
    local profileID = tostring(profile.id or "standard")
    local profileReference = math.max(finiteNumber(cfg.referencePressurePsi and cfg.referencePressurePsi[profileID], 32.0), 3.0)
    local detected = getWheelTyreProfile(wheelID)
    local internalName = detected and detected.internalName or "unknown_tyre"
    local key = normalizeTyrePressureOverrideKey(internalName)
    local override = cfg.tyreReferencePressureOverrides and cfg.tyreReferencePressureOverrides[key] or nil
    if type(override) == "number" then
        return math.max(finiteNumber(override, profileReference), 3.0), "manual-tyre", internalName
    end
    return profileReference, "profile:" .. profileID, internalName
end

local function setTyreStructuralPressureTarget(internalName, psi)
    local key = normalizeTyrePressureOverrideKey(internalName)
    if key == "" or key == "unknown_tyre" then return false end
    local numeric = tonumber(psi)
    if not numeric or numeric ~= numeric or numeric == math.huge or numeric == -math.huge then return false end
    numeric = math.max(numeric, 3.0)
    M._pressureWheelBrush.tyreReferencePressureOverrides[key] = numeric
    wheelFlashGripState = {}
    return numeric
end

local function clearTyreStructuralPressureTarget(internalName)
    local key = normalizeTyrePressureOverrideKey(internalName)
    if key == "" then return false end
    M._pressureWheelBrush.tyreReferencePressureOverrides[key] = nil
    wheelFlashGripState = {}
    return true
end

local function getBaselineGripUplift(wheelID)
    local cfg = M._baselineGripUplift
    if not cfg or not cfg.enabled then
        return 1.0, "disabled"
    end

    local detected = getWheelTyreProfile(wheelID)
    local profileId = detected and detected.profile
        and (detected.profile.classId or detected.profile.id) or "standard"
    local internalName = string.lower(tostring(detected and detected.internalName or ""))
    local override = cfg.tyreOverrides and cfg.tyreOverrides[internalName] or nil
    local value
    local source
    if type(override) == "number" then
        value = override
        source = "tyre-override"
    else
        value = cfg.profileMultipliers and cfg.profileMultipliers[profileId] or 1.0
        source = "profile:" .. tostring(profileId)
    end

    return clamp(finiteNumber(value, 1.0), 0.70, finiteNumber(cfg.maxMultiplier, 1.35)), source
end

local function getSlipPlateauRatios(wheelID, nativeUltimateRatio)
    local cfg = M._slipPlateau
    local nativeUltimate = clamp(finiteNumber(nativeUltimateRatio, 0.70), 0.05, 2.0)
    if not cfg or not cfg.enabled then
        return nativeUltimate, nativeUltimate, "disabled"
    end

    local detected = getWheelTyreProfile(wheelID)
    local profileId = detected and detected.profile and detected.profile.id or "standard"
    local internalName = string.lower(tostring(detected and detected.internalName or ""))

    local cool = cfg.coolTyreOverrides and cfg.coolTyreOverrides[internalName] or nil
    local hot = cfg.hotTyreOverrides and cfg.hotTyreOverrides[internalName] or nil
    local source = "tyre-override"
    if type(cool) ~= "number" then
        cool = cfg.coolFullSlideRatioByProfile and cfg.coolFullSlideRatioByProfile[profileId] or 0
        source = "profile:" .. tostring(profileId)
    end
    if type(hot) ~= "number" then
        hot = cfg.hotFullSlideRatioByProfile and cfg.hotFullSlideRatioByProfile[profileId] or 0
    end

    if profileId == "sport" and type(cfg.coolTyreOverrides and cfg.coolTyreOverrides[internalName]) ~= "number" then
        local sportData = tyreData and tyreData[wheelID] or nil
        local sportProfile = detected and detected.profile or TYRE_PROFILES.sport
        local sportWorking = finiteNumber(sportData and sportData.working_temp,
            finiteNumber(sportProfile and sportProfile.workingTemp, 85))
        local sportGripDepthT = finiteNumber(sportData and sportData.grip_depth_avg_temp, sportWorking)
        local sportCurveTemp = sportGripDepthT - sportWorking
            + finiteNumber(sportProfile and sportProfile.workingTemp, 85)
        local warmAnchor = math.max(finiteNumber(M._sportSemiSlick.warmFullSlideAnchor, 0.90), 0.05)
        local configuredWarm = math.max(finiteNumber(
            cfg.coolFullSlideRatioByProfile and cfg.coolFullSlideRatioByProfile.sport, warmAnchor), 0.05)
        cool = M._sportSemiSlick.getFullSlideRatio(sportCurveTemp) * configuredWarm / warmAnchor
        if RT.arcadeHandlingEnabled == true then
            local severity = clamp(finiteNumber(M._arcadeHandling.thermalPenaltySeverity, 0.60), 0.0, 1.0)
            cool = configuredWarm + (cool - configuredWarm) * severity
        end
        source = RT.arcadeHandlingEnabled == true and "profile:sport-temp-arcade60" or "profile:sport-temp"
    end

    if profileId == "race" and type(cfg.coolTyreOverrides and cfg.coolTyreOverrides[internalName]) ~= "number" then
        local raceData = tyreData and tyreData[wheelID] or nil
        local raceProfile = detected and detected.profile or TYRE_PROFILES.race
        local raceWorking = finiteNumber(raceData and raceData.working_temp,
            finiteNumber(raceProfile and raceProfile.workingTemp, 105))
        local raceGripDepthT = finiteNumber(raceData and raceData.grip_depth_avg_temp, raceWorking)
        local raceCurveTemp = raceGripDepthT - raceWorking
            + finiteNumber(raceProfile and raceProfile.workingTemp, 105)
        local warmAnchor = math.max(finiteNumber(M._slickCompounds.warmFullSlideAnchor, 0.86), 0.05)
        local configuredWarm = math.max(finiteNumber(
            cfg.coolFullSlideRatioByProfile and cfg.coolFullSlideRatioByProfile.race, warmAnchor), 0.05)
        cool = M._slickCompounds.getFullSlideRatio(raceCurveTemp) * configuredWarm / warmAnchor
        if RT.arcadeHandlingEnabled == true then
            local severity = clamp(finiteNumber(M._arcadeHandling.thermalPenaltySeverity, 0.60), 0.0, 1.0)
            cool = configuredWarm + (cool - configuredWarm) * severity
        end
        source = RT.arcadeHandlingEnabled == true and "profile:race-temp-arcade60" or "profile:race-temp"
    end

    if cool <= 0 then
        cool = nativeUltimate
    else
        cool = clamp(finiteNumber(cool, nativeUltimate), 0.05, 1.50)
    end

    if hot <= 0 then hot = cool end
    hot = clamp(finiteNumber(hot, cool), 0.05, cool)

    return cool, hot, source
end

local function setTyreProfilePreset(profileId)
    profileId = string.lower(tostring(profileId or "auto"))
    if profileId ~= "auto" and profileId ~= "rally" and not TYRE_PROFILES[profileId] then
        return false
    end

    local depthHealthBefore = {}
    for wheelID, data in pairs(tyreData or {}) do
        local oldDetected = getWheelTyreProfile(wheelID)
        local oldPhysical = M._physicalThermal.getPhysicalProfile(oldDetected and oldDetected.profile)
        depthHealthBefore[wheelID] = M._tread1D.capturePresetDepthHealth(data, oldPhysical)
    end

    MANUAL_TYRE_PROFILE = profileId
    if profileId == "auto" then
        M._physicalThermal.resetAllProfilesToPreset()
    elseif profileId == "rally" then
        M._physicalThermal.resetProfileToPreset("rally_asphalt")
        M._physicalThermal.resetProfileToPreset("rally_gravel")
    else
        local forced = TYRE_PROFILES[profileId]
        local profileKey = forced and M._physicalThermal.getProfileClassKey(forced) or profileId
        M._physicalThermal.resetProfileToPreset(profileKey)
    end
    refreshThermalPreset(true)

    if M._beamStructureTuner and M._beamStructureTuner.multipliers then
        M._beamStructureTuner.multipliers.sideSpring = 1.0
        M._beamStructureTuner.multipliers.reinfSpring = 1.0
        M._beamStructureTuner.pendingApply = true
    end

    for wheelID, data in pairs(tyreData or {}) do
        local newDetected = getWheelTyreProfile(wheelID)
        local newPhysical = M._physicalThermal.getPhysicalProfile(newDetected and newDetected.profile)
        M._tread1D.applyPresetDepthHealth(data, depthHealthBefore[wheelID], newPhysical)
    end
    return MANUAL_TYRE_PROFILE
end

local function getTyreProfilePreset()
    return MANUAL_TYRE_PROFILE
end

local CalculateTyreGrip

local function getWheelPreheatTarget(wheelID)
    local detectedTyre = getWheelTyreProfile(wheelID)
    if WORKING_TEMP >= 0 then
        return WORKING_TEMP
    end
    return detectedTyre.profile.workingTemp
end

M._advancedPreheat = M._advancedPreheat or {}
M._advancedPreheat.resolveCorner = function(wheelID)
    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wheelDef = getWheelDefForBrush and getWheelDefForBrush(wheelID) or nil
    local rawName = (wr and wr.name) or (wheelDef and wheelDef.name) or tostring(wheelID or "")
    local name = string.upper(tostring(rawName or ""))
    local compact = string.gsub(name, "[^A-Z0-9]", "")

    if compact == "FL" or compact == "LF" or compact == "WHEELFL" or compact == "TIREFL"
       or string.find(compact, "FRONTLEFT", 1, true) then return "FL" end
    if compact == "FR" or compact == "RF" or compact == "WHEELFR" or compact == "TIREFR"
       or string.find(compact, "FRONTRIGHT", 1, true) then return "FR" end
    if compact == "RL" or compact == "LR" or compact == "WHEELRL" or compact == "TIRERL"
       or string.find(compact, "REARLEFT", 1, true) then return "RL" end
    if compact == "RR" or compact == "WHEELRR" or compact == "TIRERR"
       or string.find(compact, "REARRIGHT", 1, true) then return "RR" end

    local axle = nil
    if M._beamStructureTuner and type(M._beamStructureTuner.classifyWheelAxle) == "function" then
        local ok, value = pcall(M._beamStructureTuner.classifyWheelAxle, wheelID, rawName)
        if ok then axle = value end
    end
    if axle ~= "front" and axle ~= "rear" then
        if string.find(compact, "FRONT", 1, true) or string.match(compact, "^F[LR]%d*$") then axle = "front" end
        if string.find(compact, "REAR", 1, true) or string.match(compact, "^R[LR]%d*$") then axle = "rear" end
    end

    local side = nil
    if string.find(compact, "LEFT", 1, true) or string.match(compact, "^[FR]?L%d*$")
       or string.match(compact, "L%d*$") then side = "left" end
    if string.find(compact, "RIGHT", 1, true) or string.match(compact, "^[FR]?R%d*$")
       or string.match(compact, "R%d*$") then side = "right" end

    if axle == "front" and side == "left" then return "FL" end
    if axle == "front" and side == "right" then return "FR" end
    if axle == "rear" and side == "left" then return "RL" end
    if axle == "rear" and side == "right" then return "RR" end
    return nil
end

M._advancedPreheat.normaliseTargets = function(targets)
    if type(targets) ~= "table" then return nil end
    local out, count = {}, 0
    for _, key in ipairs({"FL", "FR", "RL", "RR"}) do
        local value = targets[key]
        if value == nil then value = targets[string.lower(key)] end
        value = tonumber(value)
        if value ~= nil then
            out[key] = clamp(value, -100, 500)
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

M._advancedPreheat.getTargetForWheel = function(wheelID, targets, scalarFallback)
    targets = type(targets) == "table" and targets or nil
    local corner = targets and M._advancedPreheat.resolveCorner(wheelID) or nil
    local target = corner and tonumber(targets[corner]) or nil
    if target == nil then target = tonumber(scalarFallback) end
    if target == nil then target = getWheelPreheatTarget(wheelID) end
    return clamp(tonumber(target) or ENV_TEMP, -100, 500), corner
end

local function normalisePreheatMode(mode)
    mode = string.lower(tostring(mode or "quick"))
    if mode ~= "soaked" and mode ~= "cold" then mode = "quick" end
    return mode
end

local function setWholeTyreSoakedTemperature(data, target, physical)
    if type(data) ~= "table" then return false end
    target = clamp(finiteNumber(target, ENV_TEMP), -100, 500)

    if M._tread1D and M._tread1D.setUniform then
        M._tread1D.setUniform(data, target, physical)
    end
    data.surface_temp = type(data.surface_temp) == "table" and data.surface_temp or {}
    data.surface_boundary_temp = type(data.surface_boundary_temp) == "table" and data.surface_boundary_temp or {}
    for z = 1, 3 do
        data.surface_temp[z] = target
        data.surface_boundary_temp[z] = target
    end
    data.temp = type(data.temp) == "table" and data.temp or {target, target, target, target}
    data.temp[1], data.temp[2], data.temp[3], data.temp[4] = target, target, target, target
    data.flash_temp = target
    if M._tread1D and M._tread1D.deriveTemps then M._tread1D.deriveTemps(data, physical) end
    data.temp[4] = target
    return true
end

local function applyPreheatToWheel(wheelID, data, revision, mode, explicitTarget, options)
    if not data or type(data.temp) ~= "table" then return false end
    options = type(options) == "table" and options or {}

    mode = normalisePreheatMode(mode or pendingPreheatModes[wheelID])
    local target = explicitTarget
    if target == nil then target = pendingPreheatTargets[wheelID] end
    if target == nil then target = getWheelPreheatTarget(wheelID) end
    target = clamp(tonumber(target) or ENV_TEMP, -100, 500)
    if mode == "cold" then return false end

    local detectedTyre = getWheelTyreProfile(wheelID)
    local physical = M._physicalThermal.getPhysicalProfile(detectedTyre.profile)

    if mode == "soaked" then
        setWholeTyreSoakedTemperature(data, target, physical)
    elseif M._tread1D and M._tread1D.setOperatingWindowPreheatProfile then
        M._tread1D.setOperatingWindowPreheatProfile(data, target, physical)
    elseif M._tread1D and M._tread1D.setOperatingStartPreheat then
        M._tread1D.setOperatingStartPreheat(data, target, physical)
        M._tread1D.deriveTemps(data, physical)
    elseif M._tread1D and M._tread1D.setUniform then
        M._tread1D.setUniform(data, target, physical)
    end

    if M._circumferential and M._circumferential.clearThermal then
        M._circumferential.clearThermal(data)
    end

    local applyPressureDelta = options.applyPressureDelta ~= false
    if mode == "soaked" then
        M._applySoakedPreheatCavityState(data, wheelID, target, applyPressureDelta)
    elseif M._applyPreheatHotCavityState then
        M._applyPreheatHotCavityState(data, wheelID, target, applyPressureDelta)
    end

    data.ground_cooling_delta = 0
    data.distance_last_step = 0
    data.thermal_cache_force_publish = true
    data.b100_slow_cache_dirty = true
    data.preheat_mode_last_applied = mode
    data.preheat_target_c_last_applied = target
    if M._thermalGripCacheByWheel then M._thermalGripCacheByWheel[wheelID] = nil end
    if M._pressureWheelBrush and M._pressureWheelBrush.slowCacheByWheel then
        M._pressureWheelBrush.slowCacheByWheel[wheelID] = nil
    end
    wheelPreheatRevision[wheelID] = revision or preheatRevision
    return true, target
end

local function preheatTyres(mode, explicitTarget, options)
    options = type(options) == "table" and options or {}
    mode = normalisePreheatMode(mode)
    explicitTarget = tonumber(explicitTarget)
    if explicitTarget ~= nil then explicitTarget = clamp(explicitTarget, -100, 500) end
    local cornerTargets = M._advancedPreheat.normaliseTargets(options.cornerTargets)

    local applyThermalState = mode ~= "cold"
    local hasColdPressure = options.coldFrontPsi ~= nil or options.coldRearPsi ~= nil
    if not applyThermalState and not hasColdPressure then return 0, 0 end

    local pressureCount = 0
    if hasColdPressure and M._axlePressureOverride then
        if options.coldFrontPsi ~= nil then M._axlePressureOverride.setState("front", options.coldFrontPsi) end
        if options.coldRearPsi ~= nil then M._axlePressureOverride.setState("rear", options.coldRearPsi) end
        pressureCount = M._axlePressureOverride.applyAll(options.pressureReason or "preheat-service-cold-psi")
    end

    local appliedCount = 0
    if applyThermalState then
        preheatRevision = preheatRevision + 1
        pendingPreheatTargets = {}
        pendingPreheatModes = {}

        wheelFlashGripState = {}

        for wheelID, wheelRotator in pairs((wheels and wheels.wheelRotators) or {}) do
            local wheelTarget = M._advancedPreheat.getTargetForWheel(wheelID, cornerTargets, explicitTarget)
            pendingPreheatTargets[wheelID] = wheelTarget
            pendingPreheatModes[wheelID] = mode
            if applyPreheatToWheel(wheelID, tyreData[wheelID], preheatRevision, mode,
                    pendingPreheatTargets[wheelID], options) then
                local treadCoef = tonumber(wheelRotator and wheelRotator.treadCoef) or 1
                local grip = CalculateTyreGrip(wheelID, 0, treadCoef)
                tyreGripTable[wheelID] = grip
                M._gripRefresh.forceWheel(wheelID, grip)
                appliedCount = appliedCount + 1
            end
        end
    end

    local targetLabel = explicitTarget and string.format("%.1f", explicitTarget) or "per-wheel operating temp"
    if cornerTargets then
        targetLabel = string.format("FL %.1f / FR %.1f / RL %.1f / RR %.1f",
            finiteNumber(cornerTargets.FL, explicitTarget or 70),
            finiteNumber(cornerTargets.FR, explicitTarget or 70),
            finiteNumber(cornerTargets.RL, explicitTarget or 70),
            finiteNumber(cornerTargets.RR, explicitTarget or 70))
    end
    if appliedCount>0 and M._sportPhysicalStiffness then
        M._sportPhysicalStiffness.forceImmediateThermalSync=true
        M._sportPhysicalStiffness.sidewallThermalHasApplied=false
    end

    log("I", "luukstyrethermalsandwear", string.format(
        "PREHEAT %s applied to %d wheels at target=%s C; coldPressureWheels=%d",
        string.upper(mode), appliedCount, targetLabel, pressureCount
    ))
    return appliedCount, pressureCount
end

M._advancedPreheat.apply = function(mode, cornerTargets, options)
    options = type(options) == "table" and options or {}
    options.cornerTargets = M._advancedPreheat.normaliseTargets(cornerTargets)
    if not options.cornerTargets then return 0, 0 end
    local t = options.cornerTargets
    local fallback = (finiteNumber(t.FL, 70) + finiteNumber(t.FR, 70)
        + finiteNumber(t.RL, 70) + finiteNumber(t.RR, 70)) * 0.25
    return preheatTyres(mode, fallback, options)
end

local function resetPreheatState()
    preheatRevision = 0
    wheelPreheatRevision = {}
    pendingPreheatTargets = {}
    pendingPreheatModes = {}
end

local function armTyreProfileDetectionRetry()
    RT.tyreProfileRetryTimer = 0
    RT.tyreProfileRetryRemaining = RT.AUTO_PROFILE_RETRY_DURATION
    RT.tyreProfileDetectionSignature = ""
    RT.tyreProfileFallbackCount = 0
end

local function interpolateProfileGrip(profile, temperature)
    local points = profile.points
    if temperature <= points[1][1] then return points[1][2] end
    for i = 2, #points do
        local x1, y1 = points[i - 1][1], points[i - 1][2]
        local x2, y2 = points[i][1], points[i][2]
        if temperature <= x2 then
            local t = (temperature - x1) / math.max(x2 - x1, 0.000001)
            return lerp(y1, y2, t)
        end
    end
    return points[#points][2]
end

M._slickCompounds.getBrushThermalStiffness = function(profileID, wheelThermal)
    profileID = tostring(profileID or "")
    if (profileID ~= "race" and profileID ~= "sport" and profileID ~= "standard"
        and profileID ~= "rally_asphalt" and profileID ~= "rally_gravel")
        or type(wheelThermal) ~= "table" then
        return 1.0, ENV_TEMP
    end
    local compound
    local rallySurface
    if profileID == "race" then
        compound = M._slickCompounds.getSelected()
    elseif profileID == "sport" then
        compound = M._sportSemiSlick
    elseif profileID == "standard" then
        compound = M._standardRoad
    else
        compound, rallySurface = M._rallyCompounds.getVariantForProfile({ id = profileID })
    end
    local points = compound and compound.corneringStiffnessTempPoints or nil
    if type(points) ~= "table" or #points < 1 then return 1.0, ENV_TEMP end

    local fallbackT = finiteNumber(wheelThermal.grip_depth_avg_temp,
        finiteNumber(wheelThermal.working_temp, ENV_TEMP))
    local surfaceT = finiteNumber(wheelThermal.surface_avg_temp, fallbackT)
    local treadT = finiteNumber(wheelThermal.bulk_tread_avg_temp, fallbackT)
    local coreT = finiteNumber(wheelThermal.temp and wheelThermal.temp[4], treadT)
    local weights = rallySurface and rallySurface.structuralTempWeights
        or (compound and compound.structuralTempWeights)
        or M._slickCompounds.structuralTempWeights or {}
    local defaultCore = profileID == "standard" and 0.55
        or (profileID == "sport" and 0.60
        or (profileID == "rally_asphalt" and 0.65
        or (profileID == "rally_gravel" and 0.45 or 0.70)))
    local defaultTread = profileID == "standard" and 0.40
        or (profileID == "sport" and 0.35
        or (profileID == "rally_asphalt" and 0.30
        or (profileID == "rally_gravel" and 0.50 or 0.25)))
    local wCore = math.max(finiteNumber(weights.core, defaultCore), 0)
    local wTread = math.max(finiteNumber(weights.tread, defaultTread), 0)
    local wSurface = math.max(finiteNumber(weights.surface, 0.05), 0)
    local wSum = math.max(wCore + wTread + wSurface, 0.000001)
    local structuralTemp = (wCore * coreT + wTread * treadT + wSurface * surfaceT) / wSum

    wheelThermal.structural_b100_core_temp_c = coreT
    wheelThermal.structural_b100_tread_temp_c = treadT
    wheelThermal.structural_b100_surface_temp_c = surfaceT

    local stiffnessFactor
    if structuralTemp <= points[1][1] then
        stiffnessFactor = points[1][2]
    else
        for i = 2, #points do
            local x1, y1 = points[i - 1][1], points[i - 1][2]
            local x2, y2 = points[i][1], points[i][2]
            if structuralTemp <= x2 then
                local t = (structuralTemp - x1) / math.max(x2 - x1, 0.000001)
                stiffnessFactor = lerp(y1, y2, t)
                break
            end
        end
        if stiffnessFactor == nil then stiffnessFactor = points[#points][2] end
    end
    stiffnessFactor = M._arcadeHandling.applyThermalStiffness(stiffnessFactor)
    return stiffnessFactor, structuralTemp
end

local function AddUniqueNodeCid(list, seen, cid)
    cid = tonumber(cid)
    if cid and cid >= 0 and not seen[cid] then
        seen[cid] = true
        table.insert(list, cid)
    end
end

local function BuildWaterNodeCache()
    wheelWaterNodeCache = {}
    vehicleWaterNodeCache = {}
    wheelWaterHold = {}
    vehicleWaterHold = 0
    waterApiAvailable = nil

    local wheelCount = 0
    local wheelsWithTreadNodes = 0
    for wheelID, wheelDef in pairs((v and v.data and v.data.wheels) or {}) do
        if type(wheelID) == "number" then
            wheelCount = wheelCount + 1
            local nodeList = {}
            local seen = {}
            if type(wheelDef.treadNodes) == "table" then
                for _, cid in pairs(wheelDef.treadNodes) do
                    AddUniqueNodeCid(nodeList, seen, cid)
                end
            end
            if #nodeList > 0 then
                wheelsWithTreadNodes = wheelsWithTreadNodes + 1
            end
            wheelWaterNodeCache[wheelID] = nodeList
            wheelWaterHold[wheelID] = 0
        end
    end

    local seenVehicleNodes = {}
    for _, node in pairs((v and v.data and v.data.nodes) or {}) do
        AddUniqueNodeCid(vehicleWaterNodeCache, seenVehicleNodes, node.cid)
    end

    if wheelCount > 0 and wheelsWithTreadNodes == wheelCount then
        waterDetectionMode = "per-wheel"
    elseif #vehicleWaterNodeCache > 0 then
        waterDetectionMode = "vehicle-fallback"
    else
        waterDetectionMode = "unavailable"
    end
end

local function IsNodeInWater(cid)
    if cid == nil then return false, true end
    if waterApiAvailable == false then return false, false end

    local result
    if waterApiAvailable == nil then
        local ok
        ok, result = pcall(function()
            return obj:inWater(cid)
        end)
        if not ok then
            waterApiAvailable = false
            return false, false
        end
        waterApiAvailable = true
    else
        result = obj:inWater(cid)
    end

    if type(result) == "number" then return result > 0, true end
    return result == true, true
end

local function GetWaterContactStates(dt)
    local states = {}
    local anyWaterContact = false

    if waterDetectionMode == "per-wheel" then
        local apiAvailable = true
        for wheelID, nodeList in pairs(wheelWaterNodeCache) do
            local detected = false
            for _, cid in ipairs(nodeList) do
                local inWater, callWorked = IsNodeInWater(cid)
                if not callWorked then
                    apiAvailable = false
                    break
                end
                if inWater then
                    detected = true
                    break
                end
            end
            if not apiAvailable then break end

            if detected then
                wheelWaterHold[wheelID] = WATER_CONTACT_HOLD_SECONDS
            else
                wheelWaterHold[wheelID] = math.max((wheelWaterHold[wheelID] or 0) - dt, 0)
            end
            states[wheelID] = (wheelWaterHold[wheelID] or 0) > 0
            anyWaterContact = anyWaterContact or states[wheelID]
        end
        if apiAvailable then
            return states, anyWaterContact, "per-wheel"
        end
    end

    local detectedAnywhere = false
    local apiAvailable = true
    for _, cid in ipairs(vehicleWaterNodeCache) do
        local inWater, callWorked = IsNodeInWater(cid)
        if not callWorked then
            apiAvailable = false
            break
        end
        if inWater then
            detectedAnywhere = true
            break
        end
    end

    if not apiAvailable then
        waterDetectionMode = "unavailable"
        return states, false, "unavailable"
    end

    if detectedAnywhere then
        vehicleWaterHold = WATER_CONTACT_HOLD_SECONDS
    else
        vehicleWaterHold = math.max(vehicleWaterHold - dt, 0)
    end
    local vehicleWet = vehicleWaterHold > 0
    for wheelID, _ in pairs(wheels.wheelRotators or {}) do
        states[wheelID] = vehicleWet
    end
    return states, vehicleWet, "vehicle-fallback"
end

local function GetAmbientPressurePa()
    local ok, pressurePa = pcall(function()
        return obj:getEnvPressure()
    end)
    if ok and type(pressurePa) == "number" and pressurePa > 20000 and pressurePa < 150000 then
        ambientPressurePa = pressurePa
    end
    return ambientPressurePa or STANDARD_ATMOSPHERIC_PRESSURE_PA
end

local function GetPressureGroupID(wheelID)
    local cachedWheel = wheelCache[wheelID]
    if cachedWheel and cachedWheel.pressureGroup and v and v.data and v.data.pressureGroups then
        return v.data.pressureGroups[cachedWheel.pressureGroup]
    end
    return nil
end

local function ResolvePressureOverrideAxle(wheelID)
    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wheelName = wr and wr.name or nil
    if M._beamStructureTuner and type(M._beamStructureTuner.classifyWheelAxle) == "function" then
        local ok, axle = pcall(M._beamStructureTuner.classifyWheelAxle, wheelID, wheelName)
        if ok and (axle == "front" or axle == "rear") then return axle end
    end

    local name = string.upper(tostring(wheelName or ""))
    local compact = string.gsub(name, "[^A-Z0-9]", "")
    if compact == "FL" or compact == "FR" or string.match(compact, "^F[LR]%d*$")
       or string.find(compact, "FRONT", 1, true) then return "front" end
    if compact == "RL" or compact == "RR" or string.match(compact, "^R[LR]%d*$")
       or string.find(compact, "REAR", 1, true) then return "rear" end
    return "unknown"
end

local function GetAxlePressureOverridePsi(wheelID)
    local axle = ResolvePressureOverrideAxle(wheelID)
    if axle == "front" then
        return finiteNumber(M._axlePressureOverride.frontPsi, nil), axle
    elseif axle == "rear" then
        return finiteNumber(M._axlePressureOverride.rearPsi, nil), axle
    end
    return nil, axle
end

local function ReadVehicleTuningPressureGaugePa(wheelID)
    local wheelDef = getWheelDefForBrush and getWheelDefForBrush(wheelID)
        or (v and v.data and v.data.wheels and v.data.wheels[wheelID])
    if not wheelDef then return nil, nil end

    local pressurePSI = finiteNumber(wheelDef.pressurePSI, nil)
    local pressurePa = finiteNumber(wheelDef.pressure, nil)

    if pressurePSI and pressurePSI > 0.01 then
        return math.max(pressurePSI * PSI_TO_PA, 0), "vehicle-tuning-live-psi"
    end
    if pressurePa and pressurePa > (0.01 * PSI_TO_PA) then
        return math.max(pressurePa, 0), "vehicle-tuning-live-pa"
    end
    if pressurePSI ~= nil and pressurePSI >= 0 then
        return math.max(pressurePSI * PSI_TO_PA, 0), "vehicle-tuning-live-psi-zero"
    end
    if pressurePa ~= nil and pressurePa >= 0 then
        return math.max(pressurePa, 0), "vehicle-tuning-live-pa-zero"
    end

    return nil, nil
end

local function ReadCurrentConfiguredPressureGaugePa(wheelID)
    local overridePsi = GetAxlePressureOverridePsi(wheelID)
    if overridePsi ~= nil then
        return math.max(overridePsi * PSI_TO_PA, 0), "kts-axle-live-psi-override"
    end

    return ReadVehicleTuningPressureGaugePa(wheelID)
end

--
local function GetConfiguredPressureReferencePa(wheelID)
    local atmospherePa = GetAmbientPressurePa()
    local configuredGaugePa, configuredSource = ReadCurrentConfiguredPressureGaugePa(wheelID)
    if configuredGaugePa ~= nil then
        local old = wheelPressureReferenceCache[wheelID]
        local oldGaugePa = old and finiteNumber(old.gaugePa, nil) or nil
        local changed = oldGaugePa == nil or math.abs(oldGaugePa - configuredGaugePa) > (0.01 * PSI_TO_PA)

        wheelPressureReferenceCache[wheelID] = {
            gaugePa = configuredGaugePa,
            absolutePa = atmospherePa + configuredGaugePa,
            source = configuredSource,
            coldReferenceTempC = changed and finiteNumber(ENV_TEMP, 20)
                or finiteNumber(old and old.coldReferenceTempC, finiteNumber(ENV_TEMP, 20))
        }

        return atmospherePa + configuredGaugePa, configuredGaugePa, configuredSource
    end

    local cachedReference = wheelPressureReferenceCache[wheelID]
    if cachedReference then
        local cachedGaugePa = finiteNumber(cachedReference.gaugePa, nil)
        local cachedAbsolutePa = finiteNumber(cachedReference.absolutePa, nil)
        if cachedGaugePa and cachedGaugePa >= 0 then
            cachedGaugePa = math.max(cachedGaugePa, 0)
            return atmospherePa + cachedGaugePa, cachedGaugePa,
                cachedReference.source or "captured-cold-pressure-target"
        elseif cachedAbsolutePa and cachedAbsolutePa >= atmospherePa then
            cachedGaugePa = math.max(cachedAbsolutePa - atmospherePa, 0)
            return atmospherePa + cachedGaugePa, cachedGaugePa,
                cachedReference.source or "captured-cold-pressure-target"
        end
    end

    local fallbackGaugePa = math.max(OPTIMAL_PRESSURE, 0)
    return atmospherePa + fallbackGaugePa, fallbackGaugePa, "fallback-cold-30psi"
end

local GetTyrePressurePa

local function CaptureLivePressureReferenceIfNeeded(wheelID)
    local configuredGaugePa = ReadCurrentConfiguredPressureGaugePa(wheelID)
    if configuredGaugePa ~= nil then
        return
    end

    if wheelPressureReferenceCache[wheelID] ~= nil then return end

    local atmospherePa = GetAmbientPressurePa()
    local liveGaugePa = finiteNumber(GetTyrePressurePa(wheelID), nil)
    if liveGaugePa and liveGaugePa >= 0 then
        liveGaugePa = math.max(liveGaugePa, 0)
        wheelPressureReferenceCache[wheelID] = {
            gaugePa = liveGaugePa,
            absolutePa = atmospherePa + liveGaugePa,
            source = "live-cold-pressure-target-captured-fallback",
            coldReferenceTempC = finiteNumber(ENV_TEMP, 20)
        }
    end
end

local function ReadActualPressureGroupGaugePa(wheelID)
    local atmospherePa = GetAmbientPressurePa()
    local pressureGroupID = GetPressureGroupID(wheelID)
    if pressureGroupID ~= nil then
        local ok, absolutePressurePa = pcall(function()
            return obj:getGroupPressure(pressureGroupID)
        end)
        if ok and type(absolutePressurePa) == "number" and absolutePressurePa > 1000 then
            return math.max(absolutePressurePa - atmospherePa, 0), absolutePressurePa, "pressureGroup-live-absolute"
        end
    end
    return nil, nil, "pressureGroup-unavailable"
end

GetTyrePressurePa = function(wheelID)
    local freshGaugePa = ReadActualPressureGroupGaugePa(wheelID)
    if freshGaugePa ~= nil then
        return freshGaugePa
    end

    local wheelDef = v and v.data and v.data.wheels and v.data.wheels[wheelID]
    if wheelDef then
        local pressurePa = tonumber(wheelDef.pressure)
        if pressurePa and pressurePa >= 0 then
            return pressurePa
        end

        local pressurePSI = tonumber(wheelDef.pressurePSI)
        if pressurePSI and pressurePSI >= 0 then
            return pressurePSI * PSI_TO_PA
        end
    end

    local _, configuredGaugePa = GetConfiguredPressureReferencePa(wheelID)
    return configuredGaugePa
end

getWheelDefForBrush = function(wheelID)
    local wheelDefs = v and v.data and v.data.wheels or nil
    if type(wheelDefs) ~= "table" then return nil end
    local direct = wheelDefs[wheelID]
    if type(direct) == "table" then return direct end
    local numericID = tonumber(wheelID)
    if numericID ~= nil and type(wheelDefs[numericID]) == "table" then return wheelDefs[numericID] end
    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local targetName = wr and tostring(wr.name or "") or ""
    if targetName ~= "" then
        for _, wheelDef in pairs(wheelDefs) do
            if type(wheelDef) == "table" and tostring(wheelDef.name or "") == targetName then
                return wheelDef
            end
        end
    end
    return nil
end

local function GetWearCorneringStiffnessState(wheelID, profile, physical, wheelThermal, fixedReference)
    local wearCfg = M._wearStructuralStiffness or {}
    profile = profile or TYRE_PROFILES.standard
    local classId = tostring(profile.classId or profile.id or "standard")
    if fixedReference == true then
        return 1.0, 1.0, "fixed-reference", 0.0, 0.0, 0.0
    end

    physical = physical or M._physicalThermal.getPhysicalProfile(profile)
    local qTable = wearCfg.complianceShareByClass or {}
    local q = clamp(finiteNumber(qTable[classId], finiteNumber(qTable[tostring(profile.id or "")], 0)), 0, 0.60)
    if q <= 0 then
        return 1.0, 1.0, "disabled", 0.0, 0.0, 0.0
    end

    wheelThermal = wheelThermal or (tyreData and tyreData[wheelID] or nil)
    local totalDepth = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.0005)
    local reserve = math.max(finiteNumber(physical and physical.structuralReserveM,
        getNonWearableTreadReserveM(totalDepth)), 0)
    local wearableFresh = math.max(totalDepth - reserve, 1e-6)
    local wearableRemaining = clamp(finiteNumber(wheelThermal and wheelThermal.tread_wearable_remaining_m,
        wearableFresh), 0, wearableFresh)

    local freshGroove = math.max(finiteNumber(physical and physical.freshGrooveDepthM, 0), 0)
    local surfaceVoid = math.max(finiteNumber(physical and physical.treadVoidRatio, 0), 0)
    local useBlockHeight = freshGroove > 1e-6 and surfaceVoid > 1e-6
    local referenceDepth, remainingDepth, mode
    if useBlockHeight then
        referenceDepth = freshGroove
        remainingDepth = finiteNumber(wheelThermal and wheelThermal.tread_active_groove_depth_m, nil)
        if remainingDepth == nil then
            local wornM = math.max(wearableFresh - wearableRemaining, 0)
            remainingDepth = math.max(freshGroove - wornM, 0)
        end
        remainingDepth = clamp(remainingDepth, 0, referenceDepth)
        mode = "groove-block-height"
    else
        referenceDepth = wearableFresh
        remainingDepth = wearableRemaining
        mode = "solid-wearable-thickness"
    end

    local ratio = clamp(remainingDepth / math.max(referenceDepth, 1e-6), 0, 1)
    local factor = 1.0 / math.max((1.0 - q) + q * ratio, 0.05)
    return factor, ratio, mode, q, remainingDepth, referenceDepth
end

local function GetPressureWheelBrushCriticalSigmaY(wheelID, profile, baseSigmaY, thermalScale, currentLoadN, observerOpts)
    profile = profile or TYRE_PROFILES.standard
    local cfg = M._pressureWheelBrush or {}
    local profileID = tostring(profile.id or "standard")
    local safeBaseSigma = math.max(finiteNumber(baseSigmaY, M._flashMemory.brushCriticalSigmaYFallback), 0.001)
    local observerFixedReference = type(observerOpts) == "table" and observerOpts.fixedReference == true
    local observerReferenceTempC = observerFixedReference
        and finiteNumber(observerOpts.referenceTempC, finiteNumber(profile.workingTemp, ENV_TEMP)) or nil
    local rawThermalScale = observerFixedReference and 1.0
        or clamp(finiteNumber(thermalScale, 1), 0.05, 1.0)
    local useDynamicFiala = cfg.dynamicFialaEnabled ~= false
    local thermalScaleFloor = M._flashMemory.brushCriticalThermalScaleMin
    if useDynamicFiala and profileID == "race" then
        thermalScaleFloor = clamp(finiteNumber(M._slickCompounds.realisticBrushMuScaleMin, 0.45), 0.20, 1.0)
    elseif useDynamicFiala and (profileID == "rally_asphalt" or profileID == "rally_gravel") then
        local rallySurface = select(2, M._rallyCompounds.getVariantForProfile(profile))
        thermalScaleFloor = clamp(finiteNumber(rallySurface and rallySurface.realisticBrushMuScaleMin, 0.58), 0.20, 1.0)
    elseif useDynamicFiala and profileID == "sport" then
        thermalScaleFloor = clamp(finiteNumber(M._sportSemiSlick.realisticBrushMuScaleMin, 0.55), 0.20, 1.0)
    elseif useDynamicFiala and profileID == "standard" then
        thermalScaleFloor = clamp(finiteNumber(M._standardRoad.realisticBrushMuScaleMin, 0.70), 0.20, 1.0)
    end
    local safeThermalScale = clamp(rawThermalScale, thermalScaleFloor, 1.0)

    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wd = getWheelDefForBrush(wheelID)
    local radius = finiteNumber(wr and wr.radius, finiteNumber(wd and wd.radius, nil))
    local hubRadius = finiteNumber(wr and wr.hubRadius, finiteNumber(wd and wd.hubRadius, nil))
    local beamTreadWidth = finiteNumber(wr and wr.tireWidth, finiteNumber(wd and wd.tireWidth, finiteNumber(wd and wd.width, nil)))

    local refAspect = math.max(finiteNumber(cfg.referenceAspect and cfg.referenceAspect[profileID], 0.55), 0.10)
    local refWidth = math.max(finiteNumber(cfg.referenceWidthM and cfg.referenceWidthM[profileID], 0.225), 0.05)
    local refPressurePsi, refPressureSource, refPressureTyre = getTyreStructuralReferencePressurePsi(wheelID, profile)
    local typeFactor = clamp(finiteNumber(cfg.profileTypeStiffness and cfg.profileTypeStiffness[profileID], 1.0), 0.40, 2.50)

    local nominalGeometry = getNominalMetricTyreGeometry(wheelID)
    local geometryValid = nominalGeometry ~= nil
    local aspect = geometryValid and clamp(nominalGeometry.aspectRatio, 0.12, 1.50) or refAspect
    local safeWidth = geometryValid and clamp(nominalGeometry.sectionWidthM, 0.05, 1.20)
        or clamp(finiteNumber(beamTreadWidth, refWidth), 0.05, 1.20)
    local sidewallHeight = geometryValid and safeWidth * aspect or refAspect * refWidth
    local nominalRimRadius = geometryValid and nominalGeometry.rimRadiusM or nil

    local liveGaugePa = finiteNumber(GetTyrePressurePa(wheelID, true), refPressurePsi * PSI_TO_PA)
    local livePressurePsi = math.max(liveGaugePa / PSI_TO_PA, MIN_NUMERIC_PRESSURE_PSI)

    --
    --
    local function hewsonAspectIndex(a)
        local safeA = clamp(finiteNumber(a, refAspect), 0.12, 1.50)
        local rimR = math.max(finiteNumber(nominalRimRadius, 0.03), 0.03)
        local defTable = cfg.hewsonVerticalDeflectionByProfile or {}
        local classID = tostring(profile.classId or profileID)
        local deflection = finiteNumber(defTable[classID], finiteNumber(defTable[profileID], profileID == "race" and 0.10 or 0.15))
        deflection = clamp(deflection, 0.05, 0.25)
        local outerR = math.max(rimR + safeWidth * safeA, rimR + 0.001)
        local acosArg = clamp(1 - (deflection * safeWidth * safeA) / outerR, -1, 1)
        local theta = math.acos(acosArg)
        local sinTheta = math.max(math.sin(theta), 0.000001)
        return (safeWidth ^ 3) / math.max(outerR * outerR * sinTheta * (math.pi - sinTheta), 0.000001), deflection
    end
    local hewsonDeflection = finiteNumber((cfg.hewsonVerticalDeflectionByProfile or {})[tostring(profile.classId or profileID)],
        finiteNumber((cfg.hewsonVerticalDeflectionByProfile or {})[profileID], profileID == "race" and 0.10 or 0.15))
    local hewsonAspectFactorRaw, inverseAspectFactor = 1.0, 1.0
    if geometryValid then
        local currentAspectIndex
        currentAspectIndex, hewsonDeflection = hewsonAspectIndex(aspect)
        local referenceAspectIndex = select(1, hewsonAspectIndex(refAspect))
        hewsonAspectFactorRaw = clamp(currentAspectIndex / math.max(referenceAspectIndex, 0.000001),
            finiteNumber(cfg.minAspectFactor, 0.50), finiteNumber(cfg.maxAspectFactor, 1.80))
        inverseAspectFactor = clamp(refAspect / math.max(aspect, 0.05),
            finiteNumber(cfg.minAspectFactor, 0.50), finiteNumber(cfg.maxAspectFactor, 1.80))
    end
    local aspectStrength = clamp(finiteNumber(cfg.sidewallAspectExponent, 1.00), 0, 1.5)
    local aspectFactor = math.exp(math.log(math.max(hewsonAspectFactorRaw, 0.01)) * aspectStrength)
    local pressureFactor = (livePressurePsi / refPressurePsi) ^ clamp(finiteNumber(cfg.livePressureExponent, 0.25), 0, 1.0)
    local widthFactor = (safeWidth / refWidth) ^ clamp(finiteNumber(cfg.widthExponent, 0.10), 0, 0.75)

    local beamLogWeighted = 0
    local beamWeight = 0
    local function addBeamRatio(value, reference, weight, enabled)
        if enabled == false then return end
        local numericValue = finiteNumber(value, nil)
        if numericValue and numericValue > 0 and reference > 0 and weight > 0 then
            local ratio = clamp(numericValue / reference, 0.20, 5.0)
            beamLogWeighted = beamLogWeighted + math.log(ratio) * weight
            beamWeight = beamWeight + weight
        end
    end

    local function structuralField(name)
        local fromRotator = wr and wr[name] or nil
        if finiteNumber(fromRotator, nil) ~= nil then return fromRotator end
        return wd and wd[name] or nil
    end
    local function structuralFlag(name)
        local value = wr and wr[name]
        if value ~= nil then return value == true end
        value = wd and wd[name]
        return value == true
    end

    if type(wd) == "table" or type(wr) == "table" then
        local configuredPsi = finiteNumber(structuralField("pressurePSI"), refPressurePsi)
        local structureTune = M._beamStructureTuner and M._beamStructureTuner.multipliers or {}
        local sideTune = finiteNumber(structureTune.sideSpring, 1.0)
        local treadTune = finiteNumber(structureTune.treadSpring, 1.0)
        local reinfTune = finiteNumber(structureTune.reinfSpring, 1.0)
        local sideSpring = finiteNumber(structuralField("wheelSideBeamSpring"), nil)
        if sideSpring and configuredPsi and configuredPsi > 3 then
            addBeamRatio((sideSpring * sideTune) / configuredPsi, 550.0, 0.40, true)
        end
        addBeamRatio(finiteNumber(structuralField("wheelTreadBeamSpring"), 0) * treadTune, 50000.0, 0.22, true)
        addBeamRatio(structuralField("wheelPeripheryBeamSpring"), 35000.0, 0.13, true)
        addBeamRatio(finiteNumber(structuralField("wheelReinfBeamSpring"), 0) * reinfTune, 15000.0, 0.10,
            structuralFlag("enableTireReinfBeams") or structuralFlag("enableTireLbeams"))
        addBeamRatio(finiteNumber(structuralField("wheelTreadReinfBeamSpring"), 0) * reinfTune, 120000.0, 0.10,
            structuralFlag("enableTreadReinfBeams"))
        addBeamRatio(finiteNumber(structuralField("wheelPeripheryReinfBeamSpring"), 0) * reinfTune, 95000.0, 0.05,
            structuralFlag("enableTirePeripheryReinfBeams"))
    end

    local jbeamStructureIndex = beamWeight > 0 and math.exp(beamLogWeighted / beamWeight) or 1.0
    local jbeamInfluence = clamp(finiteNumber(cfg.jbeamStructureInfluence, 0.18), 0, 1.0)
    local jbeamStructureFactor = math.exp(math.log(math.max(jbeamStructureIndex, 0.01)) * jbeamInfluence)
    jbeamStructureFactor = clamp(jbeamStructureFactor,
        finiteNumber(cfg.minJbeamStructureFactor, 0.75),
        finiteNumber(cfg.maxJbeamStructureFactor, 1.30))

    local rawStiffness = typeFactor * aspectFactor * pressureFactor * widthFactor * jbeamStructureFactor
    rawStiffness = clamp(rawStiffness, finiteNumber(cfg.minStiffnessFactor, 0.62), finiteNumber(cfg.maxStiffnessFactor, 1.65))

    local structureStrength = (cfg.enabled == false) and 0 or clamp(finiteNumber(cfg.strength, 1.0), 0, 1.5)
    local stiffnessFactor = math.exp(math.log(math.max(rawStiffness, 0.01)) * structureStrength)

    local nominalLoadN = math.max((vehicleMass or 1500) * 9.81 / math.max(activeWheelCount or 4, 1), 50)
    local rawLoadRatio = math.max(finiteNumber(currentLoadN, nominalLoadN), 0) / nominalLoadN
    local loadRatio = clamp(rawLoadRatio,
        finiteNumber(cfg.minDynamicLoadRatio, 0.20), finiteNumber(cfg.maxDynamicLoadRatio, 3.00))
    local peakLoadRatio = math.max(finiteNumber(cfg.corneringStiffnessPeakLoadRatio, 3.0), 1.05)
    local loadShapeDen = math.max(math.sin(2 * math.atan(1 / peakLoadRatio)), 0.001)
    local corneringStiffnessLoadShape = math.sin(2 * math.atan(loadRatio / peakLoadRatio)) / loadShapeDen
    corneringStiffnessLoadShape = math.max(corneringStiffnessLoadShape, 0.05)

    local wheelThermal = tyreData and tyreData[wheelID] or nil
    local physical = M._physicalThermal.getPhysicalProfile(profile)
    local wearStiffnessFactor, wearDepthRatio, wearStiffnessMode, wearComplianceShare,
        wearRemainingDepthM, wearReferenceDepthM =
        GetWearCorneringStiffnessState(wheelID, profile, physical, wheelThermal, observerFixedReference)
    local wearRequestedStiffnessFactor = wearStiffnessFactor
    local wornFraction = clamp(1 - wearDepthRatio, 0, 1)

    local thermalCorneringStiffnessFactor, structuralTreadTempC = 1.0, ENV_TEMP
    if observerFixedReference then
        thermalCorneringStiffnessFactor = 1.0
        structuralTreadTempC = observerReferenceTempC or finiteNumber(profile.workingTemp, ENV_TEMP)
    elseif useDynamicFiala and (profileID == "race" or profileID == "sport" or profileID == "standard"
        or profileID == "rally_asphalt" or profileID == "rally_gravel") then
        thermalCorneringStiffnessFactor, structuralTreadTempC =
            M._slickCompounds.getBrushThermalStiffness(profileID, wheelThermal)
        if M._sportPhysicalStiffness
            and M._sportPhysicalStiffness.isPhysicalStiffnessWheel(wheelID) then
            local physicalCa = math.max(finiteNumber(
                M._sportPhysicalStiffness.getAppliedPhysicalCaFactor(wheelID), 1.0), 0.05)
            local desiredCombinedCa = finiteNumber(
                M._sportPhysicalStiffness.getDesiredCombinedCaFactor(wheelID), nil)
            if desiredCombinedCa == nil then
                desiredCombinedCa = math.max(thermalCorneringStiffnessFactor * wearStiffnessFactor, 0.05)
            end
            local residual = clamp(desiredCombinedCa / physicalCa, 0.50, 1.80)
            thermalCorneringStiffnessFactor = 1.0
            wearStiffnessFactor = residual
            if type(wheelThermal) == "table" then
                wheelThermal.structural_b100_physical_ca_factor = physicalCa
                wheelThermal.structural_b100_desired_combined_ca_factor = desiredCombinedCa
                wheelThermal.structural_b100_brush_residual_factor = residual
            end
        end
        thermalCorneringStiffnessFactor = clamp(finiteNumber(thermalCorneringStiffnessFactor, 1.0), 0.75, 1.60)
    end

    local sigmaStructural
    local minAngleDeg
    if useDynamicFiala then
        sigmaStructural = safeBaseSigma * safeThermalScale * loadRatio
            / math.max(stiffnessFactor * corneringStiffnessLoadShape * wearStiffnessFactor
                * thermalCorneringStiffnessFactor, 0.01)
        minAngleDeg = finiteNumber(cfg.minCriticalAngleDeg, 3.0)
    else
        sigmaStructural = safeBaseSigma * safeThermalScale / math.max(stiffnessFactor, 0.01)
        minAngleDeg = finiteNumber(cfg.minCriticalAngleDeg, 3.0)
    end

    local minSigma = math.tan(math.rad(clamp(minAngleDeg, 1.0, 45.0)))
    local maxSigma = math.tan(math.rad(clamp(finiteNumber(cfg.maxCriticalAngleDeg, 24.0), 2.0, 60.0)))
    local sigmaUsed = clamp(sigmaStructural, math.min(minSigma, maxSigma), math.max(minSigma, maxSigma))

    return sigmaUsed, {
        geometryValid = geometryValid == true,
        geometrySource = geometryValid and tostring(nominalGeometry.source or "tyre-part-metric-size") or "neutral-no-metric-size",
        radiusM = radius or 0,
        hubRadiusM = hubRadius or 0,
        beamTreadWidthM = finiteNumber(beamTreadWidth, 0),
        widthM = safeWidth,
        nominalSectionWidthM = geometryValid and nominalGeometry.sectionWidthM or 0,
        nominalAspectRatio = geometryValid and nominalGeometry.aspectRatio or 0,
        nominalRimDiameterIn = geometryValid and nominalGeometry.rimDiameterIn or 0,
        nominalRimRadiusM = geometryValid and nominalGeometry.rimRadiusM or 0,
        nominalOuterRadiusM = geometryValid and nominalGeometry.nominalOuterRadiusM or 0,
        nominalRadiusDeltaM = geometryValid and finiteNumber(nominalGeometry.runtimeRadiusDeltaM, 0) or 0,
        sidewallHeightM = sidewallHeight,
        aspectRatio = aspect,
        livePressurePsi = livePressurePsi,
        referenceAspect = refAspect,
        aspectGeometryModel = tostring(cfg.aspectGeometryModel or "hewson-relative-v2-nominal-metric-size"),
        hewsonVerticalDeflection = hewsonDeflection,
        hewsonAspectFactorRaw = hewsonAspectFactorRaw,
        inverseAspectFactor = inverseAspectFactor,
        aspectFactor = aspectFactor,
        aspectModelStrength = aspectStrength,
        profileClassId = tostring(profile.classId or profileID),
        referenceWidthM = refWidth,
        referencePressurePsi = refPressurePsi,
        referencePressureSource = refPressureSource,
        referencePressureTyre = refPressureTyre,
        typeStiffness = typeFactor,
        jbeamStructureValid = beamWeight > 0,
        jbeamStructureIndex = jbeamStructureIndex,
        jbeamStructureFactor = jbeamStructureFactor,
        rawStiffnessFactor = rawStiffness,
        stiffnessFactor = stiffnessFactor,
        dynamicFiala = useDynamicFiala == true,
        currentLoadN = finiteNumber(currentLoadN, nominalLoadN),
        nominalLoadN = nominalLoadN,
        rawLoadRatio = rawLoadRatio,
        loadRatio = loadRatio,
        corneringStiffnessLoadShape = corneringStiffnessLoadShape,
        wearStiffnessFactor = wearStiffnessFactor,
        wearRequestedStiffnessFactor = wearRequestedStiffnessFactor,
        wearDepthRatio = wearDepthRatio,
        wearStiffnessMode = wearStiffnessMode,
        wearComplianceShare = wearComplianceShare,
        wearRemainingDepthM = wearRemainingDepthM,
        wearReferenceDepthM = wearReferenceDepthM,
        thermalCorneringStiffnessFactor = thermalCorneringStiffnessFactor,
        structuralTreadTempC = structuralTreadTempC,
        muThermalScaleRaw = rawThermalScale,
        muThermalScaleUsed = safeThermalScale,
        observerReferenceNormalized = observerFixedReference == true,
        observerReferenceTempC = observerReferenceTempC,
        wornFraction = wornFraction,
        baseCriticalSigmaY = safeBaseSigma,
        structuralCriticalSigmaY = sigmaStructural,
        usedCriticalSigmaY = sigmaUsed,
        criticalAngleDeg = math.deg(math.atan(sigmaUsed)),
    }
end

M._pressureWheelBrush.slowCacheByWheel = M._pressureWheelBrush.slowCacheByWheel or {}
M._pressureWheelBrush.getThermalScaleFloor = function(profile)
    profile = profile or TYRE_PROFILES.standard
    local profileID = tostring(profile.id or "standard")
    local cfg = M._pressureWheelBrush or {}
    local useDynamicFiala = cfg.dynamicFialaEnabled ~= false
    local floor = M._flashMemory.brushCriticalThermalScaleMin
    if useDynamicFiala and profileID == "race" then
        floor = clamp(finiteNumber(M._slickCompounds.realisticBrushMuScaleMin, 0.45), 0.20, 1.0)
    elseif useDynamicFiala and (profileID == "rally_asphalt" or profileID == "rally_gravel") then
        local rallySurface = select(2, M._rallyCompounds.getVariantForProfile(profile))
        floor = clamp(finiteNumber(rallySurface and rallySurface.realisticBrushMuScaleMin, 0.58), 0.20, 1.0)
    elseif useDynamicFiala and profileID == "sport" then
        floor = clamp(finiteNumber(M._sportSemiSlick.realisticBrushMuScaleMin, 0.55), 0.20, 1.0)
    elseif useDynamicFiala and profileID == "standard" then
        floor = clamp(finiteNumber(M._standardRoad.realisticBrushMuScaleMin, 0.70), 0.20, 1.0)
    end
    return clamp(finiteNumber(floor, 0.45), 0.05, 1.0)
end

M._pressureWheelBrush.refreshSlowCache = function(wheelID, profile, baseSigmaY, thermalScale)
    profile = profile or TYRE_PROFILES.standard
    local sigma, meta = GetPressureWheelBrushCriticalSigmaY(
        wheelID, profile, baseSigmaY, thermalScale, nil, nil)
    meta = type(meta) == "table" and meta or {}
    local cache = M._pressureWheelBrush.slowCacheByWheel[wheelID] or {}
    cache.profile = profile
    cache.profileId = tostring(profile.id or "standard")
    cache.baseSigmaY = math.max(finiteNumber(baseSigmaY, meta.baseCriticalSigmaY or M._flashMemory.brushCriticalSigmaYFallback), 0.001)
    cache.thermalScaleFloor = M._pressureWheelBrush.getThermalScaleFloor(profile)
    cache.currentThermalScale = clamp(finiteNumber(thermalScale, meta.muThermalScaleUsed or 1), cache.thermalScaleFloor, 1.0)
    cache.meta = meta
    cache.nominalSigmaY = sigma
    cache.refreshCount = math.max(math.floor(finiteNumber(cache.refreshCount, 0)), 0) + 1
    cache.valid = true
    M._pressureWheelBrush.slowCacheByWheel[wheelID] = cache
    local d = tyreData and tyreData[wheelID]
    if type(d) == "table" then
        d.b100_slow_cache_refresh_count = cache.refreshCount
        d.b100_slow_cache_valid = true
    end
    return cache
end

M._pressureWheelBrush.updateCachedThermalScale = function(wheelID, thermalScale)
    local cache = M._pressureWheelBrush.slowCacheByWheel[wheelID]
    if type(cache) ~= "table" then return false end
    cache.currentThermalScale = clamp(finiteNumber(thermalScale, cache.currentThermalScale or 1),
        finiteNumber(cache.thermalScaleFloor, 0.05), 1.0)
    return true
end

M._pressureWheelBrush.getCachedCriticalSigmaY = function(wheelID, currentLoadN)
    local cache = M._pressureWheelBrush.slowCacheByWheel[wheelID]
    if type(cache) ~= "table" or cache.valid ~= true or type(cache.meta) ~= "table" then return nil, nil end
    local cfg = M._pressureWheelBrush or {}
    local meta = cache.meta
    local thermalScale = clamp(finiteNumber(cache.currentThermalScale, meta.muThermalScaleUsed or 1),
        finiteNumber(cache.thermalScaleFloor, 0.05), 1.0)
    local nominalLoadN = math.max(finiteNumber(meta.nominalLoadN, 50), 50)
    local rawLoadRatio = math.max(finiteNumber(currentLoadN, nominalLoadN), 0) / nominalLoadN
    local loadRatio = clamp(rawLoadRatio,
        finiteNumber(cfg.minDynamicLoadRatio, 0.20), finiteNumber(cfg.maxDynamicLoadRatio, 3.00))
    local peakLoadRatio = math.max(finiteNumber(cfg.corneringStiffnessPeakLoadRatio, 3.0), 1.05)
    local loadShapeDen = math.max(math.sin(2 * math.atan(1 / peakLoadRatio)), 0.001)
    local loadShape = math.sin(2 * math.atan(loadRatio / peakLoadRatio)) / loadShapeDen
    loadShape = math.max(loadShape, 0.05)
    local sigmaStructural
    if meta.dynamicFiala == true then
        sigmaStructural = math.max(finiteNumber(cache.baseSigmaY, meta.baseCriticalSigmaY), 0.001)
            * thermalScale * loadRatio
            / math.max(finiteNumber(meta.stiffnessFactor, 1)
                * loadShape
                * finiteNumber(meta.wearStiffnessFactor, 1)
                * finiteNumber(meta.thermalCorneringStiffnessFactor, 1), 0.01)
    else
        sigmaStructural = math.max(finiteNumber(cache.baseSigmaY, meta.baseCriticalSigmaY), 0.001)
            * thermalScale / math.max(finiteNumber(meta.stiffnessFactor, 1), 0.01)
    end
    local minSigma = math.tan(math.rad(clamp(finiteNumber(cfg.minCriticalAngleDeg, 3.0), 1.0, 45.0)))
    local maxSigma = math.tan(math.rad(clamp(finiteNumber(cfg.maxCriticalAngleDeg, 24.0), 2.0, 60.0)))
    local sigmaUsed = clamp(sigmaStructural, math.min(minSigma, maxSigma), math.max(minSigma, maxSigma))
    meta.currentLoadN = finiteNumber(currentLoadN, nominalLoadN)
    meta.rawLoadRatio = rawLoadRatio
    meta.loadRatio = loadRatio
    meta.corneringStiffnessLoadShape = loadShape
    meta.muThermalScaleRaw = thermalScale
    meta.muThermalScaleUsed = thermalScale
    meta.structuralCriticalSigmaY = sigmaStructural
    meta.usedCriticalSigmaY = sigmaUsed
    meta.criticalAngleDeg = math.deg(math.atan(sigmaUsed))
    return sigmaUsed, meta
end

local GetGroundModelData

--
--
local function ResetThermalPressureDeltaAnchor(data, currentAirTempC)
    if type(data) ~= "table" then return end
    data.thermal_pressure_last_applied_temp_c = finiteNumber(currentAirTempC,
        finiteNumber(data.air_temp, ENV_TEMP))
    data.thermal_pressure_cumulative_delta_pa = 0
    data.thermal_pressure_pending_delta_pa = 0
    data.thermal_pressure_delta_psi = 0
    data.thermal_pressure_ratio = 1
end

local function ApplyThermalPressureDelta(wheelID, fromAirTempC, toAirTempC, reason)
    local data = tyreData[wheelID]
    if not data then return false end

    local cfg = M._physicalThermal and M._physicalThermal.wheelCavity or {}
    local thermalInterval = math.max(finiteNumber(cfg.thermalUpdateIntervalS, 0.20), 0.05)
    data.pressure_update_hz = 1 / thermalInterval

    local liveGaugePa, liveAbsolutePa, source = ReadActualPressureGroupGaugePa(wheelID)
    if liveGaugePa ~= nil then
        data.pressure_psi = liveGaugePa / PSI_TO_PA
        data.pressure_source = source
    else
        data.pressure_psi = finiteNumber(GetTyrePressurePa(wheelID), 0) / PSI_TO_PA
        data.pressure_source = source or "pressureGroup-unavailable"
    end

    local cachedWheel = wheelCache[wheelID]
    if cachedWheel and (cachedWheel.isTireDeflated or cachedWheel.isBroken) then
        data.thermal_pressure_delta_psi = 0
        data.pressure_control_state = "beamng-native-read-deflated"
        return false
    end

    local pressureGroupID = GetPressureGroupID(wheelID)
    if pressureGroupID == nil or liveAbsolutePa == nil then
        data.thermal_pressure_delta_psi = 0
        data.pressure_control_state = "beamng-native-read-no-pressure-group"
        return false
    end

    local _, configuredGaugePa = GetConfiguredPressureReferencePa(wheelID)
    local lastConfiguredGaugePa = finiteNumber(data.thermal_pressure_last_configured_gauge_pa, nil)
    if configuredGaugePa ~= nil then
        if lastConfiguredGaugePa ~= nil and math.abs(configuredGaugePa - lastConfiguredGaugePa) > (0.01 * PSI_TO_PA) then
            ResetThermalPressureDeltaAnchor(data, fromAirTempC)
            data.pressure_control_state = "beamng-native-thermal-dT-rebased-after-tuning"
        end
        data.thermal_pressure_last_configured_gauge_pa = configuredGaugePa
    end

    local lastAppliedTempC = finiteNumber(data.thermal_pressure_last_applied_temp_c, nil)
    if lastAppliedTempC == nil then
        lastAppliedTempC = finiteNumber(fromAirTempC, finiteNumber(data.air_temp, ENV_TEMP))
        data.thermal_pressure_last_applied_temp_c = lastAppliedTempC
    end

    local fromK = clamp(lastAppliedTempC + 273.15, 150, 1000)
    local toK = clamp(finiteNumber(toAirTempC, lastAppliedTempC) + 273.15, 150, 1000)
    local ratio = toK / fromK
    local deltaPa = liveAbsolutePa * (ratio - 1)

    data.thermal_pressure_ratio = ratio
    data.thermal_pressure_pending_delta_pa = deltaPa

    local minApplyPa = math.max(finiteNumber(cfg.thermalPressureMinApplyPsi, 0.01), 0) * PSI_TO_PA
    if math.abs(deltaPa) < math.max(minApplyPa, 1e-6) then
        data.thermal_pressure_delta_psi = 0
        data.pressure_control_state = "beamng-native-read+thermal-dT-pending"
        return false
    end

    local correctedAbsolutePa = math.max(liveAbsolutePa + deltaPa, 1000)
    local ok = pcall(function()
        obj:setGroupPressure(pressureGroupID, correctedAbsolutePa)
    end)
    if not ok then
        pressureSetterAvailable = false
        data.thermal_pressure_delta_psi = 0
        data.pressure_control_state = "beamng-native-thermal-dT-setter-unavailable"
        return false
    end

    pressureSetterAvailable = true
    data.thermal_pressure_last_applied_temp_c = finiteNumber(toAirTempC, lastAppliedTempC)
    data.thermal_pressure_cumulative_delta_pa = finiteNumber(data.thermal_pressure_cumulative_delta_pa, 0) + deltaPa
    data.thermal_pressure_pending_delta_pa = 0
    data.thermal_pressure_delta_psi = deltaPa / PSI_TO_PA
    data.pressure_control_state = "beamng-native+thermal-live-delta:" .. tostring(reason or "runtime")

    local afterGaugePa, _, afterSource = ReadActualPressureGroupGaugePa(wheelID)
    if afterGaugePa ~= nil then
        data.pressure_psi = afterGaugePa / PSI_TO_PA
        data.pressure_source = afterSource
    end
    return true
end

local function UpdatePressureReadOnlyTelemetry(wheelID)
    local data = tyreData[wheelID]
    if not data then return end
    local liveGaugePa, liveAbsolutePa, source = ReadActualPressureGroupGaugePa(wheelID)
    if liveGaugePa ~= nil then
        data.pressure_psi = liveGaugePa / PSI_TO_PA
        data.pressure_source = source
    else
        data.pressure_psi = finiteNumber(GetTyrePressurePa(wheelID), 0) / PSI_TO_PA
        data.pressure_source = source or "pressureGroup-unavailable"
    end

    local _, configuredGaugePa, configuredSource = GetConfiguredPressureReferencePa(wheelID)
    data.pressure_reference_psi = configuredGaugePa / PSI_TO_PA
    data.pressure_reference_source = configuredSource

    local hotCfg = M._physicalThermal or {}
    local workingTargetC = finiteNumber(data.working_temp,
        finiteNumber(data.profile_working_temp, ENV_TEMP))
    local hotFraction = clamp(finiteNumber(hotCfg.preheatHotCavityFraction, 0.50), 0, 1.2)
    local hotAirTargetC = ENV_TEMP + (workingTargetC - ENV_TEMP) * hotFraction
    data.preheat_hot_air_target_c = hotAirTargetC
    if liveAbsolutePa ~= nil then
        local currentK = clamp(finiteNumber(data.air_temp, ENV_TEMP) + 273.15, 150, 1000)
        local hotK = clamp(hotAirTargetC + 273.15, 150, 1000)
        local predictedAbs = liveAbsolutePa * (hotK / currentK)
        data.preheat_hot_pressure_target_psi = math.max(predictedAbs - GetAmbientPressurePa(), 0) / PSI_TO_PA
    end
end

local function ApplyDirectWheelPressurePsi(wheelID, targetPsi, reason)
    targetPsi = math.max(finiteNumber(targetPsi, 0), MIN_DYNAMIC_PRESSURE_PSI)
    local pressureGroupID = GetPressureGroupID(wheelID)
    if pressureGroupID == nil then return false end
    local cachedWheel = wheelCache and wheelCache[wheelID] or nil
    if cachedWheel and (cachedWheel.isTireDeflated or cachedWheel.isBroken) then return false end

    local targetAbsolutePa = GetAmbientPressurePa() + targetPsi * PSI_TO_PA
    local ok = pcall(function()
        obj:setGroupPressure(pressureGroupID, math.max(targetAbsolutePa, 1000))
    end)
    if not ok then
        pressureSetterAvailable = false
        return false
    end

    pressureSetterAvailable = true
    local data = tyreData and tyreData[wheelID] or nil
    if type(data) == "table" then
        ResetThermalPressureDeltaAnchor(data, finiteNumber(data.air_temp, ENV_TEMP))
        data.thermal_pressure_last_configured_gauge_pa = targetPsi * PSI_TO_PA
        data.pressure_psi = targetPsi
        data.pressure_source = "kts-axle-live-psi-override"
        data.pressure_control_state = "direct-axle-psi-override:" .. tostring(reason or "user")
        UpdatePressureReadOnlyTelemetry(wheelID)
    end
    return true
end

M._axlePressureOverride.getTuningAverage = function(axle)
    axle = string.lower(tostring(axle or ""))
    if axle ~= "front" and axle ~= "rear" then return nil end
    local total, count = 0, 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if ResolvePressureOverrideAxle(wheelID) == axle then
            local gaugePa = ReadVehicleTuningPressureGaugePa(wheelID)
            if gaugePa ~= nil then
                total = total + gaugePa / PSI_TO_PA
                count = count + 1
            end
        end
    end
    return count > 0 and (total / count) or nil
end

M._axlePressureOverride.captureInitialTune = function(force)
    local state = M._axlePressureOverride
    if force or finiteNumber(state.initialFrontPsi, nil) == nil then
        state.initialFrontPsi = state.getTuningAverage("front")
    end
    if force or finiteNumber(state.initialRearPsi, nil) == nil then
        state.initialRearPsi = state.getTuningAverage("rear")
    end

    local liveFront = state.getLiveAverage and state.getLiveAverage("front") or nil
    local liveRear = state.getLiveAverage and state.getLiveAverage("rear") or nil
    local initialFront = finiteNumber(state.initialFrontPsi, nil)
    local initialRear = finiteNumber(state.initialRearPsi, nil)
    if initialFront == nil or (initialFront <= 0.01 and finiteNumber(liveFront, 0) > 0.5) then
        state.initialFrontPsi = liveFront
    end
    if initialRear == nil or (initialRear <= 0.01 and finiteNumber(liveRear, 0) > 0.5) then
        state.initialRearPsi = liveRear
    end

    state.initialFrontPsi = finiteNumber(state.initialFrontPsi, OPTIMAL_PRESSURE / PSI_TO_PA)
    state.initialRearPsi = finiteNumber(state.initialRearPsi, OPTIMAL_PRESSURE / PSI_TO_PA)

    if finiteNumber(state.frontPsi, nil) == nil then state.frontPsi = state.initialFrontPsi end
    if finiteNumber(state.rearPsi, nil) == nil then state.rearPsi = state.initialRearPsi end
    return state.initialFrontPsi, state.initialRearPsi
end

M._axlePressureOverride.getInitialTunePsi = function(axle)
    M._axlePressureOverride.captureInitialTune(false)
    axle = string.lower(tostring(axle or ""))
    if axle == "front" then return M._axlePressureOverride.initialFrontPsi end
    if axle == "rear" then return M._axlePressureOverride.initialRearPsi end
    return nil
end

M._axlePressureOverride.setState = function(axle, value)
    axle = string.lower(tostring(axle or ""))
    if axle ~= "front" and axle ~= "rear" then return false end

    M._axlePressureOverride.captureInitialTune(false)
    local raw = value
    local rawText = string.lower(tostring(raw == nil and "" or raw))
    local psi
    if raw == nil or rawText == "auto" or rawText == "" then
        psi = M._axlePressureOverride.getInitialTunePsi(axle)
    else
        psi = tonumber(raw)
    end
    if psi == nil then return false end
    psi = math.max(psi, MIN_DYNAMIC_PRESSURE_PSI)
    if axle == "front" then M._axlePressureOverride.frontPsi = psi
    else M._axlePressureOverride.rearPsi = psi end
    return psi
end

M._axlePressureOverride.applyAxle = function(axle, reason)
    axle = string.lower(tostring(axle or ""))
    local targetPsi = axle == "front" and M._axlePressureOverride.frontPsi
        or (axle == "rear" and M._axlePressureOverride.rearPsi or nil)
    if targetPsi == nil then return 0 end

    local applied = 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if ResolvePressureOverrideAxle(wheelID) == axle
           and ApplyDirectWheelPressurePsi(wheelID, targetPsi, reason) then
            applied = applied + 1
        end
    end
    return applied
end

M._axlePressureOverride.applyAll = function(reason)
    return M._axlePressureOverride.applyAxle("front", reason)
        + M._axlePressureOverride.applyAxle("rear", reason)
end

M._axlePressureOverride.setImmediate = function(axle, value)
    local result = M._axlePressureOverride.setState(axle, value)
    if result == false then return false end
    M._axlePressureOverride.applyAxle(axle, "normal-mode-edit")
    return result
end

M._axlePressureOverride.getLiveAverage = function(axle)
    axle = string.lower(tostring(axle or ""))
    local total, count = 0, 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if ResolvePressureOverrideAxle(wheelID) == axle then
            local liveGaugePa = ReadActualPressureGroupGaugePa(wheelID)
            if liveGaugePa ~= nil then
                total = total + liveGaugePa / PSI_TO_PA
                count = count + 1
            end
        end
    end
    return count > 0 and (total / count) or nil
end

local function isFrontWheelRotator(wr)
    if not wr then return false end
    local name = string.upper(tostring(wr.name or ""))
    if name == "FL" or name == "FR" or name == "F_L" or name == "F_R" then return true end
    if string.find(name, "FRONT", 1, true) then return true end
    if string.match(name, "^F[%W_]*[LR]$") then return true end
    return false
end

local function measureSteeringLockDeg()
    local best = 0
    if hydros and type(hydros.hydros) == "table" then
        for _, h in pairs(hydros.hydros) do
            if type(h) == "table" then
                local source = tostring(h.inputSource or "steering_input")
                local lock = finiteNumber(h.lockDegrees, 0)
                if (source == "steering_input" or source == "steering") and math.abs(lock) > best then
                    best = math.abs(lock)
                end
            end
        end
    end
    if best < 1 then best = 35 end
    return clamp(best, 5, 80)
end

local function measureFrontRoadWheelDeg()
    local total, count = 0, 0
    for _, wr in pairs(wheels and wheels.wheelRotators or {}) do
        if isFrontWheelRotator(wr) and wr.node1 ~= nil and wr.node2 ~= nil
            and obj and obj.nodeVecPlanarCosRightForward then
            local ok, cosAngle = pcall(obj.nodeVecPlanarCosRightForward, obj, wr.node1, wr.node2)
            if ok and type(cosAngle) == "number" then
                local angle = math.acos(clamp(cosAngle, -1, 1))
                if angle > math.pi * 0.5 then angle = math.pi - angle end
                total = total + math.abs(math.deg(angle))
                count = count + 1
            end
        end
    end
    if count > 0 then return total / count end
    local steeringInput = electrics and electrics.values and finiteNumber(electrics.values.steering_input, 0) or 0
    return math.abs(steeringInput) * measureSteeringLockDeg()
end

-- SPORT PHYSICAL STIFFNESS + MEASURED POSITIVE C_ALPHA MAP -------------------
-- Sport-family temperature sensitivity is compound-owned and AR-decoupled.
-- Native measured negative-side calibration: TreadSpring 0/37/53/74/95/100% ->
-- C_alpha 69.0/79.1/84.8/92.1/98.9/100%. Positive-side points are now measured
-- near-native extrapolations pending any future dedicated positive-side validation.
M._sportPhysicalStiffness = {
    enabled=true,
    updateIntervalS=0.20, smoothingTauS=0.60,
    updateAccumulatorS=0,
    wheelState={}, sportWheelCount=0, activeWheelCount=0,

    -- production ownership split:
    --   temperature -> desired tyre-level C_alpha ratio
    --   measured C_alpha ratio -> BeamNG tread-spring scale
    --   native tread topology/strain -> matching precompression compensation
    -- The precompression term is NOT a claimed real tyre temperature effect. It
    -- only prevents a BeamNG spring edit from also moving the tyre's native static
    -- cross-section/preload, which would contaminate the intended stiffness change.
    -- capture lifecycle. Advanced Steering keeps its calibration state
    -- private, so KTS observes the public effect instead: the spawn full-lock sweep
    -- followed by a return near centre. Then KTS holds the controls for one extra
    -- second and captures epsilon at the END of that settle window.
    calibrationPhase="WAIT_ASE",
    calibrationAgeS=0,
    aseDetected=false,
    aseSweepObserved=false,
    aseLockVisits=0,
    aseInLockZone=false,
    aseCenteredStableS=0,
    postASESettleAgeS=0,
    controlsLocked=false,
    noASEDetectionGraceS=0.35,
    aseCalibrationFallbackS=3.25,
    aseSweepLockFraction=0.55,
    aseCenteredLockFraction=0.08,
    aseCenteredMinDeg=1.5,
    aseCenteredStableRequiredS=0.10,
    postASESettleS=1.00,
    baselineCaptureMaxAttempts=10,
    minProductionEpsilon=0.0,
    maxProductionEpsilon=0.12,
    minProductionPrecompressionScale=0.50,
    maxProductionPrecompressionScale=1.05,

    -- RESEARCH-GUIDED FULL STRUCTURAL TEMPERATURE CURVE.
    -- Temperature sensitivity is now a COMPOUND-family property, not an
    -- aspect-ratio multiplier. Geometry still changes the native/B100 baseline
    -- through the Hewson pressureWheel brush model, but a 285/40 does not
    -- automatically receive more thermal softening than a 225/50 merely because
    -- it is wider/lower-profile.
    --
    -- The curve below is C_alpha(T) / C_alpha@60C. The absolute warm target is
    -- provisionally 0.85 x BeamNG native for Sport-family tyres, consistent with
    -- measured calibration data and the research range. Cold-side
    -- C_alpha may exceed native; now uses the measured positive-side
    -- spring->C_alpha transfer from the Bolide Sport calibration suite rather than
    -- the former extrapolation. Hot-side softening flattens rather than collapsing.
    structuralWorkingTempC=60.0,
    warmReferenceCaFactor=0.85,
    warmCorrectionTargetStrength=1.00,
    temperatureCaRelativeWarm={{0,1.28},{20,1.18},{40,1.08},{60,1.00},{80,0.96},{100,0.93},{130,0.90},{160,0.88}},

    standardCaFactorPoints={{-20,0.96},{0,0.94},{20,0.92},{40,0.90},{60,0.88},
        {80,0.86},{100,0.84},{120,0.82},{150,0.80},{200,0.80}},

    familyBaseStructure = {
        standard = { sideSpring = 0.80, reinfSpring = 0.89 },
        sport = { sideSpring = 0.92, reinfSpring = 0.95 },
        semi_slick = { sideSpring = 0.95, reinfSpring = 1.00 },
    },

    -- UNIVERSAL SIDEWALL-TEMPERATURE STIFFNESS.
    -- The material direction is common across tyre families: warmer sidewall /
    -- carcass rubber loses storage modulus. The complete tyre-level response is much
    -- smaller than the raw rubber-modulus change because cords, bead reinforcement
    -- and inflation support remain in parallel. Therefore this is deliberately a
    -- gentle WHOLE-SIDEWALL multiplier layered on top of each class construction
    -- baseline rather than a tread-style compound/Tg curve.
    --
    -- Sidewall thermal reservoirs already evolve slowly from explicit hysteresis,
    -- carcass/cavity/rim conduction and ambient convection. Recomputing the physical
    -- beam scale at only 2 Hz is therefore more than sufficient and avoids needless
    -- full-structure BeamNG writes. Same normalized curve is used for Standard,
    -- Sport, Semi-Slick, Race/Slick, Rally and Drift; family base stiffness remains
    -- separate. Exact factors are KTS calibration targets, not universal measured
    -- tyre-level constants.
    sidewallThermalEnabled=true,
    sidewallThermalUpdateIntervalS=0.50,
    sidewallThermalAccumulatorS=0,
    sidewallThermalHasApplied=false,
    forceImmediateThermalSync=false,
    thermalDirectionEpsilonC=0.01,
    sidewallThermalFactorPoints={
        {-20,1.08},{-10,1.06},{0,1.04},{20,1.00},{30,0.99},{40,0.975},
        {50,0.96},{60,0.945},{70,0.93},{80,0.92},{100,0.89},{120,0.86},{160,0.82}
    },

    caToTreadSpringAnchors={{0.690,0.00},{0.791,0.37},{0.848,0.53},{0.921,0.74},{0.989,0.95},{1.000,1.00},
        -- Measured positive branch from the 225/50R15 Sport constant-PSI
        -- low-angle calibration suite. Each point through 160% is measured.
        {1.040,1.10},{1.061,1.20},{1.073,1.30},{1.093,1.40},{1.108,1.50},{1.121,1.60},
        {1.152,1.84}},

    structuralPredictorEnabled=true,
    structuralBudgetBaseNpm=576088.953,
    structuralSupportSpringGain=2.24884067,
    structuralDampingRadiusGain=5109.04132,
    structuralNativeHeadroom=0.005,
    stabilityDampingMargin=0.05,
    stabilitySpringMargin=0.05,
    stabilityNumericSpringMax=6.00,

    positiveStabilityDampMin=0.95,
    positiveStabilitySpringFull=1.40,
    slickStabilityDampAtMax=0.32,
    slickStabilitySpringMax=1.84,

    localCircumferentialStiffnessEnabled=true,
    localCircumferentialApplyThreshold=0.0005,
}

M._sportPhysicalStiffness.resetRuntime=function()
    local s=M._sportPhysicalStiffness
    s.updateAccumulatorS=0
    s.sidewallThermalAccumulatorS=0
    s.sidewallThermalHasApplied=false
    s.forceImmediateThermalSync=false
    s.wheelState={}; s.sportWheelCount=0; s.activeWheelCount=0
    s.stabilityModelCache={}
    s.constructionDescriptorCache={}
    s.calibrationPhase="WAIT_ASE"
    s.calibrationAgeS=0
    s.aseDetected=false
    s.aseSweepObserved=false
    s.aseLockVisits=0
    s.aseInLockZone=false
    s.aseCenteredStableS=0
    s.postASESettleAgeS=0
    s.controlsLocked=false
end

M._sportPhysicalStiffness.capturePhysicsResetEpsilon=function()
    local s=M._sportPhysicalStiffness
    if s.calibrationPhase~="COMPLETE" then return nil end
    local out={schema=1,wheels={}}
    local count=0
    for id,st in pairs(s.wheelState or {}) do
        if type(st)=="table" and st.nativeEpsilonCaptured==true then
            local detected=RT and RT.wheelTyreProfiles and (RT.wheelTyreProfiles[id] or RT.wheelTyreProfiles[tonumber(id)]) or nil
            out.wheels[tostring(id)]={
                tyreInternalName=tostring(detected and detected.internalName or ""),
                nativeTopologyEpsilon=finiteNumber(st.nativeTopologyEpsilon,0),
                epsilonSource=tostring(st.epsilonSource or "production"),
                epsilonBeamCount=finiteNumber(st.epsilonBeamCount,0),
                epsilonLowerRejected=finiteNumber(st.epsilonLowerRejected,0),
                precompCorrectionAvailable=st.precompCorrectionAvailable==true
            }
            count=count+1
        end
    end
    if count<1 then return nil end
    out.count=count
    return out
end

M._sportPhysicalStiffness.restorePhysicsResetEpsilon=function(saved)
    local s=M._sportPhysicalStiffness
    if type(saved)~="table" or tonumber(saved.schema)~=1 or type(saved.wheels)~="table" then return false end
    local currentSportCount=0
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if s.isPhysicalStiffnessWheel(id) then
            currentSportCount=currentSportCount+1
            local src=saved.wheels[tostring(id)]
            local detected=RT and RT.wheelTyreProfiles and (RT.wheelTyreProfiles[id] or RT.wheelTyreProfiles[tostring(id)]) or nil
            local currentName=tostring(detected and detected.internalName or "")
            local savedName=tostring(src and src.tyreInternalName or "")
            if type(src)~="table" or currentName=="" or savedName=="" or currentName~=savedName then
                return false
            end
        end
    end
    if currentSportCount<1 or currentSportCount~=finiteNumber(saved.count,0) then return false end

    s.releaseCalibrationControls()
    local restored={}
    local restoredCount=0
    for key,src in pairs(saved.wheels) do
        if type(src)=="table" then
            local id=tonumber(key) or key
            local detected=RT and RT.wheelTyreProfiles and (RT.wheelTyreProfiles[id] or RT.wheelTyreProfiles[key]) or nil
            local currentName=tostring(detected and detected.internalName or "")
            local savedName=tostring(src.tyreInternalName or "")
            if currentName~="" and savedName~="" and currentName==savedName then
                restored[id]={
                    nativeEpsilonCaptured=true,
                    nativeTopologyEpsilon=finiteNumber(src.nativeTopologyEpsilon,0),
                    epsilonSource="physics-reset-preserved:"..tostring(src.epsilonSource or "production"),
                    epsilonBeamCount=finiteNumber(src.epsilonBeamCount,0),
                    epsilonLowerRejected=finiteNumber(src.epsilonLowerRejected,0),
                    precompCorrectionAvailable=src.precompCorrectionAvailable==true,
                    appliedTreadScale=1.0,
                    appliedPrecompressionScale=1.0,
                    targetTreadScale=1.0,
                    targetTreadDampScale=1.0,
                    appliedTreadDampScale=1.0,
                    temperatureC=ENV_TEMP,
                    caFactor=1.0,
                    active=false,
                    testActive=false,
                    mode="physics-reset-preserved-epsilon"
                }
                restoredCount=restoredCount+1
            end
        end
    end
    if restoredCount<1 then return false end
    s.updateAccumulatorS=0
    s.wheelState=restored; s.sportWheelCount=0; s.activeWheelCount=0
    s.calibrationPhase="COMPLETE"
    s.calibrationAgeS=0; s.aseDetected=false; s.aseSweepObserved=false
    s.aseLockVisits=0; s.aseInLockZone=false; s.aseCenteredStableS=0
    s.postASESettleAgeS=0; s.controlsLocked=false
    s.calibrationTrigger="physics-reset-preserved-epsilon"
    return true
end

M._sportPhysicalStiffness.getTemperatureCaRelativeWarm=function(tempC)
    local s=M._sportPhysicalStiffness
    local pts=s.temperatureCaRelativeWarm or {}
    local t=finiteNumber(tempC,finiteNumber(s.structuralWorkingTempC,60.0))
    if #pts<1 then return 1.0 end
    if t<=finiteNumber(pts[1][1],0) then return finiteNumber(pts[1][2],1) end
    for i=2,#pts do
        local t1,v1=finiteNumber(pts[i-1][1],0),finiteNumber(pts[i-1][2],1)
        local t2,v2=finiteNumber(pts[i][1],t1+1),finiteNumber(pts[i][2],v1)
        if t<=t2 then return lerp(v1,v2,clamp((t-t1)/math.max(t2-t1,0.000001),0,1)) end
    end
    return finiteNumber(pts[#pts][2],1)
end

M._sportPhysicalStiffness.getRealisticCaFactor=function(tempC)
    local s=M._sportPhysicalStiffness
    local relative=s.getTemperatureCaRelativeWarm(tempC)
    local warm=clamp(finiteNumber(s.warmReferenceCaFactor,0.85),0.69,1.15)
    local base=warm*relative
    local strength=clamp(finiteNumber(s.warmCorrectionTargetStrength,1.0),0.0,1.25)
    return 1.0+(base-1.0)*strength,relative,base,strength
end

M._sportPhysicalStiffness.captureNativeConstructionDescriptor=function(wheelID,refreshEpsilon)
    local s=M._sportPhysicalStiffness
    local key=tostring(wheelID)
    s.constructionDescriptorCache=s.constructionDescriptorCache or {}
    local cached=s.constructionDescriptorCache[key]
    if type(cached)=="table" then
        if refreshEpsilon~=true or finiteNumber(cached.epsilon,nil)~=nil then
            return cached,cached.epsilonReason or "cached"
        end
    end

    local tuner=M._beamStructureTuner
    if not tuner.cacheReady and not tuner.rebuildCache() then
        return nil,"structure-cache-unavailable"
    end
    if not obj or not obj.getNodePosition then return nil,"node-position-api-unavailable" end

    local wr=wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wheelFrameReady=false
    local lateral,wheelCenter,radialUp=nil,nil,nil
    if wr and wr.node1~=nil and wr.node2~=nil then
        local ok1,p1=pcall(obj.getNodePosition,obj,wr.node1)
        local ok2,p2=pcall(obj.getNodePosition,obj,wr.node2)
        if ok1 and ok2 and p1 and p2 then
            local axis=p2-p1
            if axis:length()>1e-9 then
                lateral=axis:normalized()
                wheelCenter=(p1+p2)*0.5
                local vehicleUp=vec3(0,0,1)
                radialUp=vehicleUp-lateral*lateral:dot(vehicleUp)
                if radialUp:length()<1e-9 then radialUp=vehicleUp else radialUp=radialUp:normalized() end
                wheelFrameReady=true
            end
        end
    end

    local wheelDef=getWheelDefForBrush and getWheelDefForBrush(wheelID) or nil
    local sig={
        wheelID=wheelID,
        radiusM=finiteNumber(wheelCache and wheelCache[wheelID] and wheelCache[wheelID].radius,
            finiteNumber(wheelDef and wheelDef.radius,finiteNumber(wheelDef and wheelDef.tireRadius,0.33))),
        widthM=finiteNumber(wheelCache and wheelCache[wheelID] and wheelCache[wheelID].width,
            finiteNumber(wheelDef and wheelDef.tireWidth,finiteNumber(wheelDef and wheelDef.width,0.235))),
        treadBeamCount=0,sideBeamCount=0,reinfBeamCount=0,
        treadSpringSum=0,treadDampSum=0,sideSpringSum=0,sideDampSum=0,reinfSpringSum=0,reinfDampSum=0,
    }
    local epsilonNum,epsilonDen,epsilonCount,lowerRejected=0,0,0,0

    for _,entry in ipairs(tuner.cache or {}) do
        if tostring(entry.wheelID)==key then
            local group=tostring(entry.group or "")
            local spring=entry.spring~=nil and math.max(finiteNumber(entry.spring,0),0) or nil
            local damp=entry.damp~=nil and math.max(finiteNumber(entry.damp,0),0) or nil
            if group=="tread" and spring~=nil then
                sig.treadBeamCount=sig.treadBeamCount+1
                sig.treadSpringSum=sig.treadSpringSum+spring
                sig.treadDampSum=sig.treadDampSum+(damp or 0)
            elseif group=="side" and spring~=nil then
                sig.sideBeamCount=sig.sideBeamCount+1
                sig.sideSpringSum=sig.sideSpringSum+spring
                sig.sideDampSum=sig.sideDampSum+(damp or 0)
            elseif group=="reinf" and spring~=nil then
                sig.reinfBeamCount=sig.reinfBeamCount+1
                sig.reinfSpringSum=sig.reinfSpringSum+spring
                sig.reinfDampSum=sig.reinfDampSum+(damp or 0)
            end

            if group=="tread" and wheelFrameReady and entry.id1~=nil and entry.id2~=nil then
                local okA,pA=pcall(obj.getNodePosition,obj,entry.id1)
                local okB,pB=pcall(obj.getNodePosition,obj,entry.id2)
                if okA and okB and pA and pB then
                    local d=pB-pA
                    local length=d:length()
                    if length>1e-9 then
                        local u=d:normalized()
                        local beamMid=(pA+pB)*0.5
                        if (beamMid-wheelCenter):dot(radialUp)>0 then
                            local okL,L=pcall(function() return obj:getBeamLength(entry.cid) end)
                            local okRest,Lrest=pcall(function() return obj:getBeamRestLength(entry.cid) end)
                            if okL and okRest and type(L)=="number" and type(Lrest)=="number" and Lrest>1e-9 then
                                local latAbs=math.abs(u:dot(lateral))
                                local k=math.max(spring or 1,1)
                                local weight=k*Lrest*latAbs
                                if weight>1e-12 then
                                    epsilonNum=epsilonNum+weight*(L/Lrest-1)
                                    epsilonDen=epsilonDen+weight
                                    epsilonCount=epsilonCount+1
                                end
                            end
                        else
                            lowerRejected=lowerRejected+1
                        end
                    end
                end
            end
        end
    end

    if sig.treadBeamCount<=0 or sig.treadSpringSum<=0 then return nil,"no-readable-tread-beams" end
    sig.avgTreadSpring=sig.treadSpringSum/sig.treadBeamCount
    sig.avgTreadDamp=sig.treadDampSum/sig.treadBeamCount
    sig.avgSideSpring=sig.sideBeamCount>0 and sig.sideSpringSum/sig.sideBeamCount or 0
    sig.avgSideDamp=sig.sideBeamCount>0 and sig.sideDampSum/sig.sideBeamCount or 0
    sig.avgReinfSpring=sig.reinfBeamCount>0 and sig.reinfSpringSum/sig.reinfBeamCount or 0
    sig.avgReinfDamp=sig.reinfBeamCount>0 and sig.reinfDampSum/sig.reinfBeamCount or 0
    sig.treadSpringSum,sig.treadDampSum=nil,nil
    sig.sideSpringSum,sig.sideDampSum=nil,nil
    sig.reinfSpringSum,sig.reinfDampSum=nil,nil

    local epsilon=nil
    local epsilonReason="wheel-frame-unavailable"
    if wheelFrameReady then
        if epsilonCount<1 or epsilonDen<=1e-12 then
            epsilonReason="no-readable-upper-tread-beams"
        else
            local candidate=epsilonNum/epsilonDen
            if candidate==candidate and candidate>=finiteNumber(s.minProductionEpsilon,0)
                and candidate<=finiteNumber(s.maxProductionEpsilon,0.12) then
                epsilon=candidate
                epsilonReason="TOPO_LAT_TOP50-native+shared-aggregate-reader"
            else
                epsilonReason="upper-epsilon-out-of-range"
            end
        end
    end

    local descriptor={
        wheelID=wheelID,signature=sig,structuralReadable=true,
        epsilon=epsilon,epsilonReason=epsilonReason,epsilonBeamCount=epsilonCount,
        epsilonLowerRejected=lowerRejected,
    }
    s.constructionDescriptorCache[key]=descriptor
    return descriptor,epsilonReason
end

M._sportPhysicalStiffness.getWheelConstructionSignature=function(wheelID)
    local s=M._sportPhysicalStiffness
    local d=s.constructionDescriptorCache and s.constructionDescriptorCache[tostring(wheelID)] or nil
    return type(d)=="table" and d.signature or nil
end

M._sportPhysicalStiffness.getStabilityFamilyKey=function(wheelID)
    local wr=wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local axle=M._beamStructureTuner.classifyWheelAxle(wheelID,wr and wr.name)
    if axle=="front" or axle=="rear" then return axle end
    return "wheel:"..tostring(wheelID)
end

M._sportPhysicalStiffness.buildStabilityFamilyDescriptor=function(wheelID)
    local s=M._sportPhysicalStiffness
    local familyKey=s.getStabilityFamilyKey(wheelID)
    local members={}
    local total={tread=0,side=0,reinf=0,treadK=0,treadC=0,sideK=0,sideC=0,reinfK=0,reinfC=0,radius=0,width=0}
    local wheelCount=0

    local function addMember(id)
        local d=s.constructionDescriptorCache and s.constructionDescriptorCache[tostring(id)] or nil
        if type(d)~="table" then d=s.captureNativeConstructionDescriptor(id,false) end
        local sig=type(d)=="table" and d.signature or nil
        if type(sig)~="table" or finiteNumber(sig.treadBeamCount,0)<=0 then return end
        local tc=math.max(finiteNumber(sig.treadBeamCount,0),0)
        local sc=math.max(finiteNumber(sig.sideBeamCount,0),0)
        local rc=math.max(finiteNumber(sig.reinfBeamCount,0),0)
        total.tread=total.tread+tc; total.side=total.side+sc; total.reinf=total.reinf+rc
        total.treadK=total.treadK+finiteNumber(sig.avgTreadSpring,0)*tc
        total.treadC=total.treadC+finiteNumber(sig.avgTreadDamp,0)*tc
        total.sideK=total.sideK+finiteNumber(sig.avgSideSpring,0)*sc
        total.sideC=total.sideC+finiteNumber(sig.avgSideDamp,0)*sc
        total.reinfK=total.reinfK+finiteNumber(sig.avgReinfSpring,0)*rc
        total.reinfC=total.reinfC+finiteNumber(sig.avgReinfDamp,0)*rc
        total.radius=total.radius+finiteNumber(sig.radiusM,0.33)
        total.width=total.width+finiteNumber(sig.widthM,0.235)
        members[#members+1]=id
        wheelCount=wheelCount+1
    end

    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if s.isPhysicalStiffnessWheel(id) and s.getStabilityFamilyKey(id)==familyKey then addMember(id) end
    end
    if wheelCount<1 then addMember(wheelID) end
    if wheelCount<1 or total.tread<=0 then return nil end

    local sig={
        wheelID=wheelID,
        radiusM=total.radius/wheelCount,widthM=total.width/wheelCount,
        treadBeamCount=total.tread/wheelCount,sideBeamCount=total.side/wheelCount,reinfBeamCount=total.reinf/wheelCount,
        avgTreadSpring=total.treadK/math.max(total.tread,1),avgTreadDamp=total.treadC/math.max(total.tread,1),
        avgSideSpring=total.side>0 and total.sideK/total.side or 0,avgSideDamp=total.side>0 and total.sideC/total.side or 0,
        avgReinfSpring=total.reinf>0 and total.reinfK/total.reinf or 0,avgReinfDamp=total.reinf>0 and total.reinfC/total.reinf or 0,
    }
    return {wheelID=wheelID,signature=sig,structuralReadable=true,familyKey=familyKey,familyMemberIDs=members}
end

M._sportPhysicalStiffness.isAggregateCalibrationDomainValid=function(sig)
    if type(sig)~="table" then return false,"missing-signature" end
    local treadCount=math.max(finiteNumber(sig.treadBeamCount,0),1)
    local sideRatio=finiteNumber(sig.sideBeamCount,0)/treadCount
    local reinfRatio=finiteNumber(sig.reinfBeamCount,0)/treadCount
    local function inside(v,lo,hi) v=finiteNumber(v,nil); return v~=nil and v>=lo and v<=hi end
    if sideRatio<0.85 or sideRatio>1.15 then return false,"side-tread-topology-outside-C1C2" end
    if reinfRatio<0.425 or reinfRatio>0.575 then return false,"reinf-tread-topology-outside-C1C2" end
    if not inside(sig.avgTreadSpring,136850,277150) then return false,"tread-spring-outside-C1C2" end
    if not inside(sig.avgTreadDamp,68,115) then return false,"tread-damp-outside-C1C2" end
    if not inside(sig.avgSideSpring,13260,26825) then return false,"side-spring-outside-C1C2" end
    if not inside(sig.avgReinfSpring,29750,63250) then return false,"reinf-spring-outside-C1C2" end
    if not inside(sig.radiusM,0.276,0.409) then return false,"radius-outside-C1C2" end
    local nativeSupport=math.max(finiteNumber(sig.avgSideSpring,0),0)*sideRatio
        +math.max(finiteNumber(sig.avgReinfSpring,0),0)*reinfRatio
    if nativeSupport<28100 or nativeSupport>58450 then return false,"support-outside-C1C2" end
    return true,"C1C2-calibrated-domain"
end

M._sportPhysicalStiffness.getAggregateConstructionTerms=function(model)
    local s=M._sportPhysicalStiffness
    if type(model)~="table" or type(model.signature)~="table" then return nil end
    local sig=model.signature
    local treadCount=math.max(finiteNumber(sig.treadBeamCount,0),1)
    local kT=math.max(finiteNumber(sig.avgTreadSpring,0),0)
    local cT=math.max(finiteNumber(sig.avgTreadDamp,0),0)
    if kT<=0 then return nil end

    local tuner=M._beamStructureTuner
    local m=tuner and tuner.multipliers or {}
    local wheelID=model.wheelID
    local members=model.familyMemberIDs
    local function minimumFamilyScale(tbl)
        local value=nil
        if type(members)=="table" then
            for _,id in ipairs(members) do
                local v=finiteNumber(tbl and tbl[id],1)
                value=value==nil and v or math.min(value,v)
            end
        end
        if value~=nil then return value end
        return wheelID~=nil and finiteNumber(tbl and tbl[wheelID],1) or 1
    end
    local sideFamily=minimumFamilyScale(tuner and tuner.wheelSideSpringScale)
    local reinfFamily=minimumFamilyScale(tuner and tuner.wheelReinfSpringScale)
    local sideKScale=math.min(math.max(finiteNumber(m.sideSpring,1)*sideFamily,0),1.0)
    local reinfKScale=math.min(math.max(finiteNumber(m.reinfSpring,1)*reinfFamily,0),1.0)
    local sideCScale=math.max(finiteNumber(m.sideDamp,1),0)
    local reinfCScale=math.max(finiteNumber(m.reinfDamp,1),0)
    local sideRatio=math.min(math.max(finiteNumber(sig.sideBeamCount,0)/treadCount,0),1.0)
    local reinfRatio=math.min(math.max(finiteNumber(sig.reinfBeamCount,0)/treadCount,0),0.5)
    local supportSpringEq=
        math.max(finiteNumber(sig.avgSideSpring,0),0)*sideRatio*sideKScale +
        math.max(finiteNumber(sig.avgReinfSpring,0),0)*reinfRatio*reinfKScale
    local fixedDampingEq=(
        math.max(finiteNumber(sig.avgSideDamp,0),0)*math.max(finiteNumber(sig.sideBeamCount,0),0)*sideCScale +
        math.max(finiteNumber(sig.avgReinfDamp,0),0)*math.max(finiteNumber(sig.reinfBeamCount,0),0)*reinfCScale
    )/treadCount

    local radius=clamp(finiteNumber(sig.radiusM,0.33),0.10,1.50)
    local base=math.max(finiteNumber(s.structuralBudgetBaseNpm,576088.953),1)
    local supportGain=math.max(finiteNumber(s.structuralSupportSpringGain,2.24884067),0)
    local dampingGain=math.max(finiteNumber(s.structuralDampingRadiusGain,5109.04132),0)
    local rawBudget=base+supportGain*supportSpringEq

    local nativeLoad=kT+dampingGain*radius*(fixedDampingEq+cT)
    local headroom=clamp(finiteNumber(s.structuralNativeHeadroom,0.005),0,0.05)
    local budget=math.max(rawBudget,nativeLoad*(1+headroom))
    local fixedDampingPenalty=dampingGain*radius*fixedDampingEq
    local zeroDampingCapacity=math.max(budget-fixedDampingPenalty,kT)

    local terms={
        treadSpringNpm=kT,treadDamping=cT,radiusM=radius,
        supportSpringEqNpm=supportSpringEq,fixedDampingEq=fixedDampingEq,
        rawBudgetNpm=rawBudget,budgetNpm=budget,nativeLoadNpm=nativeLoad,
        fixedDampingPenaltyNpm=fixedDampingPenalty,
        zeroDampingCapacityNpm=zeroDampingCapacity,
        dampingRadiusGain=dampingGain,
    }
    model.lastTerms=terms
    return terms
end

M._sportPhysicalStiffness.deriveConstructionStabilityModel=function(descriptor)
    local s=M._sportPhysicalStiffness
    if s.structuralPredictorEnabled~=true or type(descriptor)~="table" then return nil end
    local sig=descriptor.signature
    if type(sig)~="table" or finiteNumber(sig.treadBeamCount,0)<1
        or finiteNumber(sig.avgTreadSpring,0)<=0 then return nil end
    local domainValid,domainReason=s.isAggregateCalibrationDomainValid(sig)
    local model={
        id=string.format(domainValid and "aggregate-structure-v4:k%.0f-c%.1f-s%.0f-r%.3f"
                or "aggregate-structure-v4-domain-guard:k%.0f-c%.1f-s%.0f-r%.3f",
            finiteNumber(sig.avgTreadSpring,0),finiteNumber(sig.avgTreadDamp,0),
            finiteNumber(sig.avgSideSpring,0)+finiteNumber(sig.avgReinfSpring,0),
            finiteNumber(sig.radiusM,0.33)),
        source=domainValid and "C1/C2-calibrated aggregate construction stability budget"
            or "outside C1/C2 calibration domain; conservative legacy guard",
        calibrationDomainValid=domainValid,calibrationDomainReason=domainReason,
        derived=true,wheelID=descriptor.wheelID,familyKey=descriptor.familyKey or s.getStabilityFamilyKey(descriptor.wheelID),
        familyMemberIDs=descriptor.familyMemberIDs,signature=sig,descriptor=descriptor,
    }
    if s.getAggregateConstructionTerms(model)==nil then return nil end
    return model
end

M._sportPhysicalStiffness.getConstructionStabilityModel=function(wheelID)
    local s=M._sportPhysicalStiffness
    s.stabilityModelCache=s.stabilityModelCache or {}
    local familyKey=s.getStabilityFamilyKey(wheelID)
    local cacheKey="family:"..familyKey
    local cached=s.stabilityModelCache[cacheKey]
    if type(cached)=="table" then return cached end
    local descriptor=s.buildStabilityFamilyDescriptor(wheelID)
    if type(descriptor)~="table" then return nil end
    local model=s.deriveConstructionStabilityModel(descriptor)
    if model then s.stabilityModelCache[cacheKey]=model end
    return model
end

M._sportPhysicalStiffness.calculateZeroDampingSpringLimit=function(model)
    local s=M._sportPhysicalStiffness
    local t=s.getAggregateConstructionTerms(model)
    if not t then return nil end
    local raw=t.zeroDampingCapacityNpm/math.max(t.treadSpringNpm,1)
    model.predictedZeroDampingMaxStable=raw
    return clamp(raw,1.0,finiteNumber(s.stabilityNumericSpringMax,6.0))
end

M._sportPhysicalStiffness.getConstructionSafeSpringLimit=function(wheelID)
    local s=M._sportPhysicalStiffness
    local model=s.getConstructionStabilityModel(wheelID)
    if model then
        if model.calibrationDomainValid~=true then
            local fallback=math.max(1.0,finiteNumber(s.slickStabilitySpringMax,1.84)-finiteNumber(s.stabilitySpringMargin,0.05))
            return fallback,model
        end
        local raw=s.calculateZeroDampingSpringLimit(model)
        if raw~=nil then
            local safe=math.max(1.0,raw-finiteNumber(s.stabilitySpringMargin,0.05))
            return clamp(safe,1.0,finiteNumber(s.stabilityNumericSpringMax,6.0)),model
        end
    end
    return math.max(1.0,finiteNumber(s.slickStabilitySpringMax,1.84)-finiteNumber(s.stabilitySpringMargin,0.05)),nil
end

M._sportPhysicalStiffness.predictConstructionDampingCeiling=function(model,treadScale)
    local s=M._sportPhysicalStiffness
    local t=s.getAggregateConstructionTerms(model)
    if not t then return nil end
    local spring=math.max(finiteNumber(treadScale,1.0),0)
    local numerator=t.budgetNpm-t.treadSpringNpm*spring-t.fixedDampingPenaltyNpm
    local denominator=t.dampingRadiusGain*t.radiusM*t.treadDamping
    if denominator<=1e-9 then
        return numerator>=0 and 1.0 or -1.0
    end
    return clamp(numerator/denominator,-1.0,1.0)
end

M._sportPhysicalStiffness.getLegacyStabilityDampScale=function(treadScale,profileID)
    local s=M._sportPhysicalStiffness
    local k=finiteNumber(treadScale,1.0)
    if k<=1.0 then return 1.0 end
    if tostring(profileID or "")=="race" then
        local kMax=math.max(finiteNumber(s.slickStabilitySpringMax,1.84),1.01)
        local minD=clamp(finiteNumber(s.slickStabilityDampAtMax,0.32),0.0,1.0)
        local u=clamp((k-1.0)/math.max(kMax-1.0,0.01),0,1)
        local smooth=u*u*(3.0-2.0*u)
        return 1.0-(1.0-minD)*smooth
    end
    local roadFull=math.max(finiteNumber(s.positiveStabilitySpringFull,1.40)-1.0,0.05)
    local roadMinD=clamp(finiteNumber(s.positiveStabilityDampMin,0.95),0.80,1.0)
    if k<=1.0+roadFull then
        local u=clamp((k-1.0)/roadFull,0,1)
        return 1.0-(1.0-roadMinD)*u
    end
    local kMax=math.max(finiteNumber(s.slickStabilitySpringMax,1.84),1.41)
    local extremeMinD=clamp(finiteNumber(s.slickStabilityDampAtMax,0.32),0.0,roadMinD)
    local u=clamp((k-(1.0+roadFull))/math.max(kMax-(1.0+roadFull),0.01),0,1)
    local smooth=u*u*(3.0-2.0*u)
    return roadMinD-(roadMinD-extremeMinD)*smooth
end

M._sportPhysicalStiffness.getStabilityDampScale=function(treadScale,profileID,wheelID)
    local s=M._sportPhysicalStiffness
    local k=finiteNumber(treadScale,1.0)
    if k<=1.0 then return 1.0 end
    local model=wheelID~=nil and s.getConstructionStabilityModel(wheelID) or nil
    if model and model.calibrationDomainValid==true then
        local safeSpring=s.getConstructionSafeSpringLimit(wheelID)
        if k>=safeSpring-0.001 then return 0.0 end
        local ceiling=s.predictConstructionDampingCeiling(model,k)
        if ceiling~=nil then
            if ceiling>=1.0 then return 1.0 end
            return clamp(ceiling-finiteNumber(s.stabilityDampingMargin,0.05),0.0,1.0)
        end
    end
    return s.getLegacyStabilityDampScale(k,profileID)
end

M._sportPhysicalStiffness.caFactorToTreadScale=function(ca,maxScale)
    local s=M._sportPhysicalStiffness
    local a=s.caToTreadSpringAnchors or {{1.0,1.0}}
    local minCa=finiteNumber(a[1][1],1.0)
    local numericMax=finiteNumber(maxScale,finiteNumber(s.stabilityNumericSpringMax,6.0))
    ca=math.max(finiteNumber(ca,1),minCa)
    if ca<=minCa then return finiteNumber(a[1][2],1.0) end
    for i=2,#a do
        local x1,y1=finiteNumber(a[i-1][1],1),finiteNumber(a[i-1][2],0)
        local x2,y2=finiteNumber(a[i][1],x1+0.01),finiteNumber(a[i][2],y1)
        if ca<=x2 then
            return clamp(lerp(y1,y2,(ca-x1)/math.max(x2-x1,0.000001)),0,numericMax)
        end
    end
    if #a>=2 then
        local x1,y1=finiteNumber(a[#a-1][1],1),finiteNumber(a[#a-1][2],1)
        local x2,y2=finiteNumber(a[#a][1],x1+0.01),finiteNumber(a[#a][2],y1)
        local slope=(y2-y1)/math.max(x2-x1,0.000001)
        return clamp(y2+(ca-x2)*slope,0,numericMax)
    end
    return clamp(finiteNumber(a[#a][2],1.0),0,numericMax)
end

M._sportPhysicalStiffness.getGeometry=function(wheelID)
    local wr=wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wd=getWheelDefForBrush(wheelID)
    local beamWidth=finiteNumber(wr and wr.tireWidth,finiteNumber(wd and wd.tireWidth,finiteNumber(wd and wd.width,0.235)))
    local nominal=getNominalMetricTyreGeometry(wheelID)
    local width=nominal and nominal.sectionWidthM or beamWidth
    width=clamp(width,0.10,0.50)
    local aspect=nominal and clamp(nominal.aspectRatio,0.20,0.90) or 0.45
    return width,aspect,1.0
end

M._sportPhysicalStiffness.captureNativeTopologyEpsilon=function(wheelID)
    local s=M._sportPhysicalStiffness
    local descriptor,reason=s.captureNativeConstructionDescriptor(wheelID,true)
    if type(descriptor)~="table" then return nil,reason or "structure-descriptor-unavailable",0 end
    local epsilon=finiteNumber(descriptor.epsilon,nil)
    if epsilon==nil then
        return nil,descriptor.epsilonReason or reason or "epsilon-unavailable",
            finiteNumber(descriptor.epsilonBeamCount,0),finiteNumber(descriptor.epsilonLowerRejected,0)
    end
    return epsilon,descriptor.epsilonReason or "TOPO_LAT_TOP50-native+shared-structure-reader",
        finiteNumber(descriptor.epsilonBeamCount,0),finiteNumber(descriptor.epsilonLowerRejected,0)
end

M._sportPhysicalStiffness.precompressionForSpring=function(epsilon,springScale)
    local s=M._sportPhysicalStiffness
    local e=clamp(finiteNumber(epsilon,0),finiteNumber(s.minProductionEpsilon,0),finiteNumber(s.maxProductionEpsilon,0.12))
    local k=math.max(finiteNumber(springScale,1),0.05)
    local pre=1-e*(1/k-1)
    return clamp(pre,finiteNumber(s.minProductionPrecompressionScale,0.50),finiteNumber(s.maxProductionPrecompressionScale,1.05))
end

M._sportPhysicalStiffness.ensureNativeTopologyEpsilon=function(wheelID,st,allowImmediate)
    local s=M._sportPhysicalStiffness
    st=st or {}
    if st.nativeEpsilonCaptured==true then
        if not (s.constructionDescriptorCache and s.constructionDescriptorCache[tostring(wheelID)]) then
            s.captureNativeConstructionDescriptor(wheelID)
        end
        return finiteNumber(st.nativeTopologyEpsilon,0)
    end
    if not allowImmediate and s.calibrationPhase~="COMPLETE" then
        st.epsilonSource="waiting-"..string.lower(tostring(s.calibrationPhase or "calibration"))
        return nil
    end
    local e,source,count,rejected=s.captureNativeTopologyEpsilon(wheelID)
    st.epsilonCaptureAttempts=finiteNumber(st.epsilonCaptureAttempts,0)+1
    st.epsilonBeamCount=finiteNumber(count,0)
    st.epsilonLowerRejected=finiteNumber(rejected,0)
    if e~=nil then
        st.nativeEpsilonCaptured=true
        st.nativeTopologyEpsilon=e
        st.epsilonSource=source or "TOPO_LAT_TOP50-native"
        st.precompCorrectionAvailable=true
        return e
    end
    st.epsilonSource=source or "topology-unavailable"
    if st.epsilonCaptureAttempts>=finiteNumber(s.baselineCaptureMaxAttempts,10) then
        st.nativeEpsilonCaptured=true
        st.nativeTopologyEpsilon=0
        st.epsilonSource="fallback-no-precomp:"..tostring(st.epsilonSource)
        st.precompCorrectionAvailable=false
        return 0
    end
    return nil
end

M._sportPhysicalStiffness.detectAdvancedSteering=function()
    local steerState=input and input.state and input.state.steering or nil
    if steerState and tostring(steerState.filter or "")=="ADVANCED_STEERING" then return true end
    local ext=rawget(_G,"extensions")
    if type(ext)=="table" then
        for name,module in pairs(ext) do
            local key=string.lower(tostring(name or ""))
            if type(module)=="table" and string.find(key,"advancedsteering",1,true)
                and type(module.state)=="table" and type(module.state.steering)=="table" then
                return true
            end
        end
    end
    return false
end

M._sportPhysicalStiffness.hasSportWheel=function()
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if M._sportPhysicalStiffness.isSportWheel(id) then return true end
    end
    return false
end

M._sportPhysicalStiffness.hasPhysicalStiffnessWheel=function()
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if M._sportPhysicalStiffness.isPhysicalStiffnessWheel(id) then return true end
    end
    return false
end

M._sportPhysicalStiffness.lockCalibrationControls=function()
    local s=M._sportPhysicalStiffness
    local filter=(type(FILTER_DIRECT)=="number" and FILTER_DIRECT or 2)
    if input and type(input.event)=="function" then
        pcall(input.event,"steering",0,filter)
        pcall(input.event,"throttle",0,filter)
        pcall(input.event,"brake",1,filter)
        pcall(input.event,"parkingbrake",1,filter)
        s.controlsLocked=true
    end
end

M._sportPhysicalStiffness.releaseCalibrationControls=function()
    local s=M._sportPhysicalStiffness
    if not s.controlsLocked then return end
    local filter=(type(FILTER_DIRECT)=="number" and FILTER_DIRECT or 2)
    if input and type(input.event)=="function" then
        pcall(input.event,"steering",0,filter)
        pcall(input.event,"throttle",0,filter)
        pcall(input.event,"brake",0,filter)
        pcall(input.event,"parkingbrake",0,filter)
    end
    s.controlsLocked=false
end

M._sportPhysicalStiffness.captureAllNativeEpsilon=function()
    local s=M._sportPhysicalStiffness
    local allResolved=true
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if s.isPhysicalStiffnessWheel(id) then
            local st=s.wheelState[id] or {}; s.wheelState[id]=st
            if st.nativeEpsilonCaptured~=true then
                local e=s.ensureNativeTopologyEpsilon(id,st,true)
                if e==nil then allResolved=false end
            end
        end
    end
    return allResolved
end

M._sportPhysicalStiffness.beginPostASESettle=function(reason)
    local s=M._sportPhysicalStiffness
    if s.calibrationPhase=="POST_ASE_SETTLE" or s.calibrationPhase=="COMPLETE" then return end
    s.calibrationPhase="POST_ASE_SETTLE"
    s.postASESettleAgeS=0
    s.calibrationTrigger=tostring(reason or "unknown")
end

M._sportPhysicalStiffness.updateCalibrationLifecycle=function(dt)
    local s=M._sportPhysicalStiffness
    dt=math.max(finiteNumber(dt,0),0)
    if s.calibrationPhase=="COMPLETE" then return true end
    if s.enabled~=true or not s.hasPhysicalStiffnessWheel() then return false end

    if s.calibrationPhase=="WAIT_ASE" then
        s.calibrationAgeS=finiteNumber(s.calibrationAgeS,0)+dt
        local aseNow=s.detectAdvancedSteering()
        if aseNow then s.aseDetected=true end
        if s.aseDetected then
            local angle=finiteNumber(measureFrontRoadWheelDeg(),0)
            local lock=math.max(finiteNumber(measureSteeringLockDeg(),35),5)
            local lockZone=math.max(4.0,lock*finiteNumber(s.aseSweepLockFraction,0.55))
            local centerZone=math.max(finiteNumber(s.aseCenteredMinDeg,1.5),lock*finiteNumber(s.aseCenteredLockFraction,0.08))
            if angle>=lockZone then
                s.aseSweepObserved=true
                if not s.aseInLockZone then
                    s.aseLockVisits=finiteNumber(s.aseLockVisits,0)+1
                    s.aseInLockZone=true
                end
            elseif angle<=centerZone then
                s.aseInLockZone=false
                if finiteNumber(s.aseLockVisits,0)>=2 then
                    s.aseCenteredStableS=finiteNumber(s.aseCenteredStableS,0)+dt
                else
                    s.aseCenteredStableS=0
                end
            else
                s.aseCenteredStableS=0
            end
            if finiteNumber(s.aseLockVisits,0)>=2 and s.aseCenteredStableS>=finiteNumber(s.aseCenteredStableRequiredS,0.10) then
                s.beginPostASESettle("ase-two-lock-sweep-complete")
            elseif s.calibrationAgeS>=finiteNumber(s.aseCalibrationFallbackS,3.25) then
                s.beginPostASESettle("ase-timeout-or-skip")
            end
        elseif s.calibrationAgeS>=finiteNumber(s.noASEDetectionGraceS,0.35) then
            s.beginPostASESettle("no-ase-detected")
        end
    end

    if s.calibrationPhase=="POST_ASE_SETTLE" then
        s.lockCalibrationControls()
        s.postASESettleAgeS=finiteNumber(s.postASESettleAgeS,0)+dt
        if s.postASESettleAgeS>=finiteNumber(s.postASESettleS,1.0) then
            if s.captureAllNativeEpsilon() then
                s.calibrationPhase="COMPLETE"
                s.releaseCalibrationControls()
                return true
            end
        end
    end
    return s.calibrationPhase=="COMPLETE"
end

M._sportPhysicalStiffness.captureRewindState=function()
    local s=M._sportPhysicalStiffness
    local out={schema=1, calibrationComplete=s.calibrationPhase=="COMPLETE", wheels={}}
    for id,st in pairs(s.wheelState or {}) do
        if type(st)=="table" and st.nativeEpsilonCaptured==true then
            out.wheels[id]={
                nativeEpsilonCaptured=true,
                nativeTopologyEpsilon=finiteNumber(st.nativeTopologyEpsilon,0),
                epsilonSource=tostring(st.epsilonSource or "restored"),
                epsilonBeamCount=finiteNumber(st.epsilonBeamCount,0),
                epsilonLowerRejected=finiteNumber(st.epsilonLowerRejected,0),
                precompCorrectionAvailable=st.precompCorrectionAvailable==true,
                baseAppliedTreadScale=finiteNumber(st.baseAppliedTreadScale,finiteNumber(st.appliedTreadScale,1)),
                appliedTreadScale=finiteNumber(st.appliedTreadScale,1),
                appliedPrecompressionScale=finiteNumber(st.appliedPrecompressionScale,1),
                targetTreadScale=finiteNumber(st.targetTreadScale,1),
                temperatureC=finiteNumber(st.temperatureC,ENV_TEMP),
                caFactor=finiteNumber(st.caFactor,1)
            }
        end
    end
    return out
end

M._sportPhysicalStiffness.restoreRewindState=function(saved)
    local s=M._sportPhysicalStiffness
    if type(saved)~="table" or tonumber(saved.schema)~=1 then return false end
    s.releaseCalibrationControls()
    s.wheelState={}
    for key,src in pairs(saved.wheels or {}) do
        if type(src)=="table" and src.nativeEpsilonCaptured==true then
            local id=tonumber(key) or key
            s.wheelState[id]={
                nativeEpsilonCaptured=true,
                nativeTopologyEpsilon=finiteNumber(src.nativeTopologyEpsilon,0),
                epsilonSource="rewind:"..tostring(src.epsilonSource or "saved"),
                epsilonBeamCount=finiteNumber(src.epsilonBeamCount,0),
                epsilonLowerRejected=finiteNumber(src.epsilonLowerRejected,0),
                precompCorrectionAvailable=src.precompCorrectionAvailable==true,
                baseAppliedTreadScale=finiteNumber(src.baseAppliedTreadScale,finiteNumber(src.appliedTreadScale,1)),
                appliedTreadScale=finiteNumber(src.appliedTreadScale,finiteNumber(src.baseAppliedTreadScale,1)),
                appliedPrecompressionScale=finiteNumber(src.appliedPrecompressionScale,1),
                targetTreadScale=finiteNumber(src.targetTreadScale,1),
                temperatureC=finiteNumber(src.temperatureC,ENV_TEMP),
                caFactor=finiteNumber(src.caFactor,1),
                active=true,
                testActive=false,
                mode="rewind-restored-epsilon"
            }
        end
    end
    if saved.calibrationComplete==true then
        s.calibrationPhase="COMPLETE"
        s.calibrationAgeS=0; s.postASESettleAgeS=0; s.controlsLocked=false
    else
        s.calibrationPhase="WAIT_ASE"
        s.calibrationAgeS=0; s.aseDetected=false; s.aseSweepObserved=false
        s.aseLockVisits=0; s.aseInLockZone=false; s.aseCenteredStableS=0
        s.postASESettleAgeS=0; s.controlsLocked=false
    end
    return true
end

M._sportPhysicalStiffness.applyRestoredStructure=function()
    local s=M._sportPhysicalStiffness
    local changed=false
    local dampingPrimed=false
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if s.isPhysicalStiffnessWheel(id) then
            local st=s.wheelState[id] or s.wheelState[tostring(id)]
            if type(st)=="table" and st.nativeEpsilonCaptured==true then
                local safeSpringLimit=s.getConstructionSafeSpringLimit(id)
                local applied=clamp(finiteNumber(st.baseAppliedTreadScale,
                    finiteNumber(st.appliedTreadScale,1)),0,safeSpringLimit)
                st.baseAppliedTreadScale=applied
                st.appliedTreadScale=applied
                local pre=s.precompressionForSpring(st.nativeTopologyEpsilon,applied)
                st.appliedPrecompressionScale=pre
                if s.wheelState[id]==nil then s.wheelState[id]=st end
                local damp=s.getStabilityDampScale(applied,s.getWheelProfileId(id),id)
                st.appliedTreadDampScale=damp; st.targetTreadDampScale=damp

                -- PRIME DAMPING ONE GFX FRAME BEFORE RESTORED STIFFNESS.
                -- KTS engineering mitigation for rewind-reset transients: write only
                -- the saved spring's matching damping now while retaining whatever
                -- spring BeamNG currently has after RESET_PHYSICS. The three setters
                -- below merely stage the saved bulk structure; pendingApply is then
                -- consumed by _beamStructureTuner.update() at the START of the next
                -- updateGFX frame. This deliberately creates:
                --   restore frame N   : damping only
                --   updateGFX frame N+1: spring + same damping + precompression
                -- rather than asking a fragile race tyre to accept the spring jump
                -- and damping correction in the same rewind restore instant.
                if M._beamStructureTuner.applyWheelTreadDampOnlyFast(id,damp) then
                    dampingPrimed=true
                end
                if M._beamStructureTuner.setWheelTreadScale(id,applied,true) then changed=true end
                if M._beamStructureTuner.setWheelTreadDampScale(id,damp,true) then changed=true end
                if M._beamStructureTuner.setWheelTreadPrecompressionScale(id,pre,true) then changed=true end
            end
        end
    end
    if changed then
        M._beamStructureTuner.pendingApply=true
        log("I", "luukstyrethermalsandwear", string.format(
            "KTS rewind structure staged: dampingPrimed=%s fullStructure=next-GFX-frame",
            tostring(dampingPrimed)))
        return true
    end
    return true
end

M._sportPhysicalStiffness.getStandardCaFactor=function(tempC)
    local s=M._sportPhysicalStiffness
    local pts=s.standardCaFactorPoints or {{20,0.92}}
    local t=finiteNumber(tempC,20.0)
    if #pts<1 then return 0.92 end
    if t<=finiteNumber(pts[1][1],-20) then return finiteNumber(pts[1][2],0.96) end
    for i=2,#pts do
        local t1,v1=finiteNumber(pts[i-1][1],0),finiteNumber(pts[i-1][2],1)
        local t2,v2=finiteNumber(pts[i][1],t1+1),finiteNumber(pts[i][2],v1)
        if t<=t2 then return lerp(v1,v2,clamp((t-t1)/math.max(t2-t1,0.000001),0,1)) end
    end
    return finiteNumber(pts[#pts][2],0.80)
end

M._sportPhysicalStiffness.getRaceCaFactor=function(tempC)
    local compound=M._slickCompounds.getSelected()
    local pts=compound and compound.corneringStiffnessTempPoints or nil
    local t=finiteNumber(tempC,ENV_TEMP)
    if type(pts)~="table" or #pts<1 then return 1.0 end
    if t<=finiteNumber(pts[1][1],0) then return finiteNumber(pts[1][2],1.0) end
    for i=2,#pts do
        local t1,v1=finiteNumber(pts[i-1][1],0),finiteNumber(pts[i-1][2],1)
        local t2,v2=finiteNumber(pts[i][1],t1+1),finiteNumber(pts[i][2],v1)
        if t<=t2 then return lerp(v1,v2,clamp((t-t1)/math.max(t2-t1,0.000001),0,1)) end
    end
    return finiteNumber(pts[#pts][2],1.0)
end

M._sportPhysicalStiffness.treadScaleToCaFactor=function(scale)
    local s=M._sportPhysicalStiffness
    local a=s.caToTreadSpringAnchors or {{1.0,1.0}}
    local y=clamp(finiteNumber(scale,1.0),finiteNumber(a[1][2],0),
        finiteNumber(s.stabilityNumericSpringMax,6.0))
    if y<=finiteNumber(a[1][2],0) then return finiteNumber(a[1][1],1.0) end
    for i=2,#a do
        local x1,y1=finiteNumber(a[i-1][1],1),finiteNumber(a[i-1][2],0)
        local x2,y2=finiteNumber(a[i][1],x1),finiteNumber(a[i][2],y1+0.01)
        if y<=y2 then return lerp(x1,x2,clamp((y-y1)/math.max(y2-y1,0.000001),0,1)) end
    end
    if #a>=2 then
        local x1,y1=finiteNumber(a[#a-1][1],1),finiteNumber(a[#a-1][2],1)
        local x2,y2=finiteNumber(a[#a][1],x1+0.01),finiteNumber(a[#a][2],y1)
        local slope=(x2-x1)/math.max(y2-y1,0.000001)
        return x2+(y-y2)*slope
    end
    return finiteNumber(a[#a][1],1.0)
end

M._sportPhysicalStiffness.getAppliedPhysicalCaFactor=function(wheelID)
    local s=M._sportPhysicalStiffness
    local st=s.wheelState and s.wheelState[wheelID] or nil
    if type(st)~="table" or st.active~=true then return 1.0 end
    return s.treadScaleToCaFactor(finiteNumber(st.baseAppliedTreadScale,finiteNumber(st.appliedTreadScale,1.0)))
end

M._sportPhysicalStiffness.getDesiredCombinedCaFactor=function(wheelID)
    local s=M._sportPhysicalStiffness
    local st=s.wheelState and s.wheelState[wheelID] or nil
    if type(st)~="table" or st.active~=true then return nil end
    return finiteNumber(st.desiredCombinedCaFactor,finiteNumber(st.caFactor,nil))
end

M._sportPhysicalStiffness.getBrushResidualCaFactor=function(wheelID)
    local s=M._sportPhysicalStiffness
    local st=s.wheelState and s.wheelState[wheelID] or nil
    if type(st)~="table" or st.active~=true then return 1.0 end
    return finiteNumber(st.brushResidualCaFactor,1.0)
end

M._sportPhysicalStiffness.predictWheel=function(wheelID,tempC)
    local s=M._sportPhysicalStiffness
    local w,a,geometryThermalScale=s.getGeometry(wheelID)
    local profileID=s.getWheelProfileId(wheelID)
    local profileClassId=s.getWheelProfileClassId(wheelID)
    local profileInfo=getWheelTyreProfile(wheelID)
    local profile=profileInfo and profileInfo.profile or TYRE_PROFILES.standard
    local realisticCa,relativeWarm,rawBaseCa,strength
    if profileID=="standard" then
        rawBaseCa=s.getStandardCaFactor(tempC)
        strength=clamp(finiteNumber(s.warmCorrectionTargetStrength,1.0),0.0,1.25)
        realisticCa=1.0+(rawBaseCa-1.0)*strength
        relativeWarm=rawBaseCa/math.max(s.getStandardCaFactor(60.0),0.001)
    elseif profileID=="race" then
        rawBaseCa=s.getRaceCaFactor(tempC)
        realisticCa=rawBaseCa
        local selected=M._slickCompounds.getSelected()
        local working=finiteNumber(selected and selected.profile and selected.profile.workingTemp,105.0)
        relativeWarm=rawBaseCa/math.max(s.getRaceCaFactor(working),0.001)
        strength=1.0
    else
        realisticCa,relativeWarm,rawBaseCa,strength=s.getRealisticCaFactor(tempC)
    end

    local arcadeAuthority=M._arcadeHandling.getPhysicalStiffnessAuthority(tempC)
    local thermalCa=realisticCa
    local physical=(thermalCache and thermalCache.physical) or M._physicalThermal.getPhysicalProfile(profile)
    local data=tyreData and tyreData[wheelID] or nil
    local wearCa,wearDepthRatio,wearMode,wearQ,wearRemainingDepthM,wearReferenceDepthM=
        GetWearCorneringStiffnessState(wheelID,profile,physical,data,false)
    local realisticCombinedCa=math.max(thermalCa*wearCa,0.05)
    local combinedCa=1.0+(realisticCombinedCa-1.0)*arcadeAuthority

    local anchors=s.caToTreadSpringAnchors or {{0.69,0.0},{1.152,1.84}}
    local minPhysicalCa=finiteNumber(anchors[1][1],0.69)
    local safeSpringLimit,stabilityModel=s.getConstructionSafeSpringLimit(wheelID)
    local maxPhysicalCa=s.treadScaleToCaFactor(safeSpringLimit)
    local physicalCaTarget=clamp(combinedCa,minPhysicalCa,maxPhysicalCa)
    local brushResidual=combinedCa/math.max(physicalCaTarget,0.05)
    local treadScale=s.caFactorToTreadScale(physicalCaTarget,safeSpringLimit)
    local dampScale=s.getStabilityDampScale(treadScale,profileID,wheelID)

    return {temperatureC=finiteNumber(tempC,ENV_TEMP),widthM=w,aspectRatio=a,maxDrop=0,
        geometryThermalScale=geometryThermalScale,relativeWarmCa=relativeWarm,rawBaseCa=rawBaseCa,
        realisticCaFactor=realisticCa,warmTargetStrength=strength,
        arcadeStiffnessAuthority=arcadeAuthority,softeningProgress=1-relativeWarm,
        thermalCaFactor=thermalCa,wearCaFactor=wearCa,wearDepthRatio=wearDepthRatio,
        wearMode=wearMode,wearComplianceShare=wearQ,wearRemainingDepthM=wearRemainingDepthM,
        wearReferenceDepthM=wearReferenceDepthM,realisticCombinedCaFactor=realisticCombinedCa,
        desiredCombinedCaFactor=combinedCa,physicalCaTarget=physicalCaTarget,
        brushResidualCaFactor=brushResidual,caFactor=physicalCaTarget,
        treadScale=treadScale,treadDampScale=dampScale,profileClassId=profileClassId,
        stabilityModelId=stabilityModel and stabilityModel.id or "legacy-last-fallback",
        stabilityFamilyKey=stabilityModel and stabilityModel.familyKey or s.getStabilityFamilyKey(wheelID),
        stabilitySafeSpringLimit=safeSpringLimit}
end

M._sportPhysicalStiffness.getWheelProfileId=function(wheelID)
    local d=getWheelTyreProfile(wheelID)
    return tostring(d and d.profile and d.profile.id or "")
end

M._sportPhysicalStiffness.getWheelProfileClassId=function(wheelID)
    local d=getWheelTyreProfile(wheelID)
    return tostring(d and d.profile and (d.profile.classId or d.profile.id) or "")
end

M._sportPhysicalStiffness.getFamilyBaseStructure=function(wheelID)
    local s=M._sportPhysicalStiffness
    local classId=s.getWheelProfileClassId(wheelID)
    local cfg=s.familyBaseStructure and s.familyBaseStructure[classId] or nil
    return finiteNumber(cfg and cfg.sideSpring,1.0), finiteNumber(cfg and cfg.reinfSpring,1.0), classId
end

M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure=function()
    local s=M._sportPhysicalStiffness
    local classId=M._physicalThermal.getAdvancedProfileKey()
    local cfg=s.familyBaseStructure and s.familyBaseStructure[classId] or nil
    return finiteNumber(cfg and cfg.sideSpring,1.0), finiteNumber(cfg and cfg.reinfSpring,1.0), classId
end

M._sportPhysicalStiffness.isSportWheel=function(wheelID)
    return M._sportPhysicalStiffness.getWheelProfileId(wheelID)=="sport"
end

M._sportPhysicalStiffness.isPhysicalStiffnessWheel=function(wheelID)
    local id=M._sportPhysicalStiffness.getWheelProfileId(wheelID)
    return id=="sport" or id=="standard" or id=="race"
end

M._sportPhysicalStiffness.getLiveSidewallTempC=function(wheelID)
    local data=tyreData and tyreData[wheelID] or nil
    if type(data)~="table" then return ENV_TEMP end
    local fallback=finiteNumber(data.temp and data.temp[4],ENV_TEMP)
    local outer=finiteNumber(data.sidewall_outer_temp,fallback)
    local inner=finiteNumber(data.sidewall_inner_temp,fallback)
    return (outer+inner)*0.5
end

M._sportPhysicalStiffness.getSidewallThermalFactor=function(tempC)
    local s=M._sportPhysicalStiffness
    if s.sidewallThermalEnabled~=true or M._thermalPause.active==true then return 1.0 end
    local points=s.sidewallThermalFactorPoints or {}
    if #points<1 then return 1.0 end
    local tC=finiteNumber(tempC,ENV_TEMP)
    local factor=nil
    if tC<=finiteNumber(points[1][1],tC) then
        factor=finiteNumber(points[1][2],1.0)
    else
        for i=2,#points do
            local x1=finiteNumber(points[i-1][1],tC)
            local y1=finiteNumber(points[i-1][2],1.0)
            local x2=finiteNumber(points[i][1],x1+1)
            local y2=finiteNumber(points[i][2],y1)
            if tC<=x2 then
                local u=clamp((tC-x1)/math.max(x2-x1,0.000001),0,1)
                factor=lerp(y1,y2,u)
                break
            end
        end
        if factor==nil then factor=finiteNumber(points[#points][2],1.0) end
    end
    return clamp(M._arcadeHandling.applyThermalStiffness(factor),0.70,1.20)
end

M._sportPhysicalStiffness.updateUniversalSidewallStiffness=function()
    local s=M._sportPhysicalStiffness
    local changed=false
    local sidewallInterval=math.max(finiteNumber(s.sidewallThermalUpdateIntervalS,0.50),0.10)
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        local st=s.wheelState[id] or {}
        s.wheelState[id]=st
        local familySide,familyReinf,familyClass=s.getFamilyBaseStructure(id)
        local sidewallTemp=s.getLiveSidewallTempC(id)
        local sidewallFactor=s.getSidewallThermalFactor(sidewallTemp)
        local liveSideScale=clamp(familySide*sidewallFactor,0.0,2.0)
        st.familyClassId=familyClass
        st.familySideSpringScale=familySide
        st.familyReinfSpringScale=familyReinf
        st.sidewallThermalInitialized=true
        st.sidewallTemperatureC=sidewallTemp
        st.sidewallThermalFactor=sidewallFactor
        st.liveSideSpringScale=liveSideScale
        if M._beamStructureTuner.setWheelFamilyBaseScales(id,liveSideScale,familyReinf) then changed=true end
        local data=tyreData and tyreData[id] or nil
        if type(data)=="table" then
            data.sidewall_stiffness_temp_c=sidewallTemp
            data.sidewall_stiffness_thermal_factor=sidewallFactor
            data.sidewall_live_spring_scale=liveSideScale
            data.sidewall_base_spring_scale=familySide
            data.sidewall_stiffness_update_hz=1/math.max(sidewallInterval,0.0001)
        end
    end
    s.sidewallThermalHasApplied=true
    return changed
end

M._sportPhysicalStiffness.getLiveStructuralTempC=function(wheelID)
    local data=tyreData and tyreData[wheelID] or nil
    if type(data)~="table" then return ENV_TEMP end
    local profileID=M._sportPhysicalStiffness.getWheelProfileId(wheelID)
    if profileID~="sport" and profileID~="standard" and profileID~="race" then profileID="sport" end
    local _,t=M._slickCompounds.getBrushThermalStiffness(profileID,data)
    return finiteNumber(t,finiteNumber(data.bulk_tread_avg_temp,ENV_TEMP))
end

M._sportPhysicalStiffness.getLocalStructuralDeltaC=function(wheelID)
    local s=M._sportPhysicalStiffness
    local data=tyreData and tyreData[wheelID] or nil
    local d=type(data) == "table" and data.circumferential_contact_layer_delta_c or nil
    if type(d)~="table" then
        if type(data)=="table" then data.circumferential_contact_structural_temp_delta_c=0 end
        return 0
    end
    local profileID=s.getWheelProfileId(wheelID)
    local compound=profileID=="standard" and M._standardRoad
        or (profileID=="race" and M._slickCompounds.getSelected() or M._sportSemiSlick)
    local weights=compound and compound.structuralTempWeights or M._slickCompounds.structuralTempWeights or {}
    local defaultCore=profileID=="standard" and 0.55 or (profileID=="race" and 0.70 or 0.60)
    local defaultTread=profileID=="standard" and 0.40 or (profileID=="race" and 0.25 or 0.35)
    local wCore=math.max(finiteNumber(weights.core,defaultCore),0)
    local wTread=math.max(finiteNumber(weights.tread,defaultTread),0)
    local wSurface=math.max(finiteNumber(weights.surface,0.05),0)
    local wSum=math.max(wCore+wTread+wSurface,0.000001)
    local treadDelta=(finiteNumber(d[1],0)*1 + finiteNumber(d[2],0)*2
        + finiteNumber(d[3],0)*3 + finiteNumber(d[4],0)*4) / 12
    local surfaceDelta=finiteNumber(d[1],0)
    local structuralDelta=(wTread*treadDelta + wSurface*surfaceDelta) / wSum
    if type(data)=="table" then
        data.circumferential_contact_structural_temp_delta_c=structuralDelta
        data.circumferential_contact_structural_tread_delta_c=treadDelta
        data.circumferential_contact_structural_surface_delta_c=surfaceDelta
    end
    return structuralDelta
end

M._sportPhysicalStiffness.applyLocalCircumferentialStiffness=function()
    local s=M._sportPhysicalStiffness
    if s.localCircumferentialStiffnessEnabled~=true or M._thermalPause.active==true then return false end
    local any=false
    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        if s.isPhysicalStiffnessWheel(id) then
            local st=s.wheelState[id]
            if type(st)=="table" and st.active==true and st.testActive~=true then
                local baseTemp=finiteNumber(st.temperatureC,s.getLiveStructuralTempC(id))
                local baseApplied=finiteNumber(st.baseAppliedTreadScale,finiteNumber(st.appliedTreadScale,1))
                local localDelta=s.getLocalStructuralDeltaC(id)
                local localTemp=baseTemp+localDelta
                local basePrediction=s.predictWheel(id,baseTemp)
                local localPrediction=s.predictWheel(id,localTemp)
                local ratio=finiteNumber(localPrediction.treadScale,1)
                    / math.max(finiteNumber(basePrediction.treadScale,1),0.0001)
                local safeSpringLimit=s.getConstructionSafeSpringLimit(id)
                local desired=clamp(baseApplied*ratio,0.0,safeSpringLimit)
                local localProfileId=s.getWheelProfileId(id)
                local desiredDamp=s.getStabilityDampScale(desired,localProfileId,id)
                if st.dampingPrimeHold==true then
                    desired=math.min(desired,baseApplied)
                    desiredDamp=math.min(desiredDamp,
                        finiteNumber(st.appliedTreadDampScale,
                            finiteNumber(st.dampingPrimeTargetDamp,desiredDamp)))
                end
                local threshold=math.max(finiteNumber(s.localCircumferentialApplyThreshold,0.0005),0.00001)
                local structureRevision=finiteNumber(M._beamStructureTuner.revision,0)
                local lastPhysical=finiteNumber(st.localActuatorAppliedScale,baseApplied)
                local revisionChanged=finiteNumber(st.localActuatorStructureRevision,-1)~=structureRevision
                st.localStructuralDeltaC=localDelta
                st.localStructuralTempC=localTemp
                st.localTreadScaleRatio=ratio
                st.localTargetTreadScale=desired
                st.appliedTreadScale=desired
                local data=tyreData and tyreData[id] or nil
                if type(data)=="table" then
                    data.circumferential_contact_tread_stiffness_ratio=ratio
                    data.circumferential_contact_tread_spring_scale=desired
                    data.circumferential_contact_tread_damp_scale=desiredDamp
                end

                local localIsBulk=math.abs(desired-baseApplied)<=threshold
                if revisionChanged and localIsBulk then
                    st.localActuatorAppliedScale=baseApplied
                    st.localActuatorAppliedDampScale=finiteNumber(st.appliedTreadDampScale,desiredDamp)
                    st.localActuatorStructureRevision=structureRevision
                elseif revisionChanged or math.abs(lastPhysical-desired)>threshold then
                    if M._beamStructureTuner.applyWheelTreadSpringFast(id,desired,desiredDamp,lastPhysical) then
                        st.localActuatorAppliedScale=desired
                        st.localActuatorAppliedDampScale=desiredDamp
                        st.localActuatorStructureRevision=structureRevision
                        any=true
                    end
                end
            end
        end
    end
    return any
end

M._sportPhysicalStiffness.update=function(dt)
    local s=M._sportPhysicalStiffness
    dt=math.max(finiteNumber(dt,0),0)
    local paused=M._thermalPause.active==true

    s.updateCalibrationLifecycle(dt)
    s.updateAccumulatorS=finiteNumber(s.updateAccumulatorS,0)+dt
    s.sidewallThermalAccumulatorS=finiteNumber(s.sidewallThermalAccumulatorS,0)+dt

    local forceThermalSync=s.forceImmediateThermalSync==true
    local sidewallInterval=math.max(finiteNumber(s.sidewallThermalUpdateIntervalS,0.50),0.10)
    local sidewallDue=forceThermalSync or s.sidewallThermalHasApplied~=true
        or s.sidewallThermalAccumulatorS>=sidewallInterval
    local sidewallChanged=false
    if sidewallDue then
        s.sidewallThermalAccumulatorS=0
        sidewallChanged=s.updateUniversalSidewallStiffness()
    end

    local interval=math.max(finiteNumber(s.updateIntervalS,0.20),0.02)
    if s.updateAccumulatorS<interval and not forceThermalSync then
        if sidewallChanged then
            M._beamStructureTuner.pendingApply=true
            M._beamStructureTuner.apply()
        end
        s.applyLocalCircumferentialStiffness()
        return
    end
    local step=math.max(s.updateAccumulatorS,0.001)
    s.updateAccumulatorS=0
    s.forceImmediateThermalSync=false
    local changed=sidewallChanged
    local sportCount,activeCount=0,0

    for id,_ in pairs((wheels and wheels.wheelRotators) or {}) do
        local sport=s.isSportWheel(id)
        if sport then sportCount=sportCount+1 end
        local physical=s.isPhysicalStiffnessWheel(id)
        local liveOwns=physical and s.enabled==true and not paused
        local st=s.wheelState[id] or {}
        s.wheelState[id]=st

        local epsilon=nil
        if liveOwns then epsilon=s.ensureNativeTopologyEpsilon(id,st,false) end
        local owns=epsilon~=nil and liveOwns

        if owns then
            activeCount=activeCount+1
            local pr=s.predictWheel(id,s.getLiveStructuralTempC(id))
            local target=pr.treadScale
            local targetDamp=clamp(finiteNumber(pr.treadDampScale,
                s.getStabilityDampScale(target,s.getWheelProfileId(id),id)),0.0,1.50)
            local prev=finiteNumber(st.baseAppliedTreadScale,finiteNumber(st.appliedTreadScale,1))
            local prevDamp=finiteNumber(st.appliedTreadDampScale,1.0)
            local previousStructuralTemp=finiteNumber(st.temperatureC,pr.temperatureC)
            local thermalDeltaC=pr.temperatureC-previousStructuralTemp
            local thermalEps=math.max(finiteNumber(s.thermalDirectionEpsilonC,0.01),0.0001)
            local alpha=1-math.exp(-math.max(step,0.001)/math.max(finiteNumber(s.smoothingTauS,0.60),0.02))
            local applied=prev+(target-prev)*alpha
            local dampScale=targetDamp

            local heatingSoftens=(thermalDeltaC>thermalEps and target<prev-0.0005)
            local coolingStiffens=(thermalDeltaC<-thermalEps and target>prev+0.0005)
            if heatingSoftens then applied=target end
            local preScale=s.precompressionForSpring(epsilon,applied)

            local transitionPrimeOK=true
            local needsFinalDampPrime=(targetDamp<prevDamp-0.0005)
            if heatingSoftens then
                transitionPrimeOK=M._beamStructureTuner.applyWheelTreadSpringFast(id,applied,nil,prev)==true
                st.dampingPrimeHold=false
                st.dampingPrimeTargetSpring=target
                st.dampingPrimeTargetDamp=targetDamp
                st.thermalTransitionMode="heat-up-spring-immediate"
                if not transitionPrimeOK then
                    applied=prev
                    preScale=s.precompressionForSpring(epsilon,applied)
                    dampScale=prevDamp
                end
            elseif needsFinalDampPrime then
                transitionPrimeOK=M._beamStructureTuner.applyWheelTreadDampOnlyFast(id,targetDamp)==true
                if transitionPrimeOK then
                    applied=prev
                    preScale=s.precompressionForSpring(epsilon,applied)
                    dampScale=targetDamp
                    st.dampingPrimeHold=true
                    st.dampingPrimeTargetSpring=target
                    st.dampingPrimeTargetDamp=targetDamp
                    st.thermalTransitionMode=coolingStiffens and "heat-down-damp-immediate" or "damp-prime"
                else
                    applied=prev
                    preScale=s.precompressionForSpring(epsilon,applied)
                    dampScale=prevDamp
                    st.dampingPrimeHold=true
                    st.thermalTransitionMode="damp-prime-write-failed"
                end
            else
                st.dampingPrimeHold=false
                st.dampingPrimeTargetSpring=target
                st.dampingPrimeTargetDamp=targetDamp
                st.thermalTransitionMode="normal"
                if applied<prev-0.0005 and targetDamp>prevDamp+0.0005 then
                    transitionPrimeOK=M._beamStructureTuner.applyWheelTreadSpringFast(id,applied,nil,prev)==true
                    if not transitionPrimeOK then dampScale=prevDamp end
                end
            end
            st.active=true
            st.testActive=false
            st.temperatureC=pr.temperatureC
            st.widthM=pr.widthM
            st.aspectRatio=pr.aspectRatio
            st.maxDrop=0
            st.geometryThermalScale=pr.geometryThermalScale
            st.relativeWarmCa=pr.relativeWarmCa
            st.rawBaseCa=pr.rawBaseCa
            st.realisticCaFactor=pr.realisticCaFactor
            st.warmTargetStrength=pr.warmTargetStrength
            st.arcadeStiffnessAuthority=pr.arcadeStiffnessAuthority
            st.softeningProgress=pr.softeningProgress
            st.caFactor=pr.caFactor
            st.thermalCaFactor=pr.thermalCaFactor
            st.wearCaFactor=pr.wearCaFactor
            st.wearDepthRatio=pr.wearDepthRatio
            st.wearMode=pr.wearMode
            st.wearComplianceShare=pr.wearComplianceShare
            st.wearRemainingDepthM=pr.wearRemainingDepthM
            st.wearReferenceDepthM=pr.wearReferenceDepthM
            st.realisticCombinedCaFactor=pr.realisticCombinedCaFactor
            st.desiredCombinedCaFactor=pr.desiredCombinedCaFactor
            st.physicalCaTarget=pr.physicalCaTarget
            st.brushResidualCaFactor=pr.brushResidualCaFactor
            st.targetTreadScale=target
            st.baseAppliedTreadScale=applied
            st.appliedTreadScale=applied
            st.localStructuralDeltaC=0
            st.localStructuralTempC=pr.temperatureC
            st.localTreadScaleRatio=1
            st.localTargetTreadScale=applied
            st.targetTreadDampScale=pr.treadDampScale
            st.appliedTreadDampScale=dampScale
            st.stabilityModelId=pr.stabilityModelId
            st.stabilityFamilyKey=pr.stabilityFamilyKey
            st.stabilitySafeSpringLimit=pr.stabilitySafeSpringLimit
            st.appliedPrecompressionScale=preScale
            local liveProfileId=s.getWheelProfileId(id)
            st.mode=(liveProfileId=="standard")
                and "standard-live-temperature+wear+auto-precomp"
                or ((liveProfileId=="race")
                    and "slick-live-temperature+wear+construction-coupled-damping+brush-residual"
                    or "live-temperature+wear+auto-precomp+stability-damp")
            local liveData=tyreData and tyreData[id] or nil
            if type(liveData)=="table" then
                liveData.wear_stiffness_ca_factor=finiteNumber(pr.wearCaFactor,1)
                liveData.wear_stiffness_depth_ratio=finiteNumber(pr.wearDepthRatio,1)
                liveData.wear_stiffness_depth_mode=tostring(pr.wearMode or "unknown")
                liveData.wear_stiffness_compliance_share=finiteNumber(pr.wearComplianceShare,0)
                liveData.thermal_structural_ca_factor=finiteNumber(pr.thermalCaFactor,1)
                liveData.combined_structural_ca_requested=finiteNumber(pr.desiredCombinedCaFactor,1)
                liveData.combined_structural_ca_physical=finiteNumber(pr.physicalCaTarget,1)
                liveData.combined_structural_ca_brush_residual=finiteNumber(pr.brushResidualCaFactor,1)
                liveData.structure_stability_model_id=tostring(pr.stabilityModelId or "legacy-last-fallback")
                liveData.structure_stability_family_key=tostring(pr.stabilityFamilyKey or s.getStabilityFamilyKey(id))
                liveData.structure_stability_safe_spring_limit=finiteNumber(pr.stabilitySafeSpringLimit,1.84)
                liveData.structure_stability_damping_scale=dampScale
            end
            if M._beamStructureTuner.setWheelTreadScale(id,applied,true) then changed=true end
            if M._beamStructureTuner.setWheelTreadDampScale(id,dampScale,true) then changed=true end
            if M._beamStructureTuner.setWheelTreadPrecompressionScale(id,preScale,true) then changed=true end
        else
            st.active=false
            st.testActive=false
            if physical and st.nativeEpsilonCaptured~=true and s.enabled==true and not paused then
                st.mode="waiting-"..string.lower(tostring(s.calibrationPhase or "native-topology"))
            else
                st.mode=physical and (paused and "thermal-off-native" or "disabled-native") or "non-stiffness-family-native"
            end
            st.temperatureC=physical and s.getLiveStructuralTempC(id) or ENV_TEMP
            st.caFactor=1
            st.thermalCaFactor=1
            st.wearCaFactor=1
            st.wearDepthRatio=1
            st.wearMode="inactive"
            st.wearComplianceShare=0
            st.realisticCombinedCaFactor=1
            st.desiredCombinedCaFactor=1
            st.physicalCaTarget=1
            st.brushResidualCaFactor=1
            st.targetTreadScale=1
            st.baseAppliedTreadScale=1
            st.appliedTreadScale=1
            st.localStructuralDeltaC=0
            st.localStructuralTempC=st.temperatureC
            st.localTreadScaleRatio=1
            st.localTargetTreadScale=1
            st.localActuatorAppliedScale=1
            st.localActuatorStructureRevision=finiteNumber(M._beamStructureTuner.revision,0)
            st.targetTreadDampScale=1
            st.appliedTreadDampScale=1
            st.appliedPrecompressionScale=1
            if M._beamStructureTuner.clearWheelTreadScale(id) then changed=true end
            if M._beamStructureTuner.clearWheelTreadDampScale(id) then changed=true end
            if M._beamStructureTuner.clearWheelTreadPrecompressionScale(id) then changed=true end
        end
    end

    if changed then
        M._beamStructureTuner.pendingApply=true
        M._beamStructureTuner.apply()
    end
    s.applyLocalCircumferentialStiffness()
    s.sportWheelCount=sportCount
    s.activeWheelCount=activeCount
end

M._sportPhysicalStiffness.getSummary=function()
    local s=M._sportPhysicalStiffness; local first=nil; local firstId=nil; local firstSafe=nil
    local function consider(id,st,activeOnly)
        if not s.isPhysicalStiffnessWheel(id) or type(st)~="table" then return end
        if activeOnly and st.active~=true then return end
        local safe=s.getConstructionSafeSpringLimit(id); safe=finiteNumber(safe,1.84)
        if first==nil or safe<firstSafe then first=st; firstId=id; firstSafe=safe end
    end
    for id,st in pairs(s.wheelState or {}) do consider(id,st,true) end
    if first==nil then for id,st in pairs(s.wheelState or {}) do consider(id,st,false) end end
    first=first or {}

    local function familyInfo(key)
        local safe,model,count,dampSum,targetDampSum=nil,nil,0,0,0
        for id,st in pairs(s.wheelState or {}) do
            if s.isPhysicalStiffnessWheel(id) and s.getStabilityFamilyKey(id)==key and type(st)=="table" then
                local thisSafe,thisModel=s.getConstructionSafeSpringLimit(id)
                safe=finiteNumber(thisSafe,safe or 1.84); model=thisModel or model
                if st.active==true then
                    dampSum=dampSum+finiteNumber(st.appliedTreadDampScale,1)
                    targetDampSum=targetDampSum+finiteNumber(st.targetTreadDampScale,1)
                    count=count+1
                end
            end
        end
        return {safe=finiteNumber(safe,0),model=model,count=count,
            damp=count>0 and dampSum/count or 0,targetDamp=count>0 and targetDampSum/count or 0}
    end
    local frontFamily=familyInfo("front")
    local rearFamily=familyInfo("rear")
    local stabilityModel = firstId~=nil and s.getConstructionStabilityModel(firstId) or nil
    local stabilitySignature = stabilityModel and stabilityModel.signature or nil
    return {enabled=s.enabled==true,sport_wheels=finiteNumber(s.sportWheelCount,0),
        active_wheels=finiteNumber(s.activeWheelCount,0),mode=first.mode or "waiting-for-sport-wheel",
        structural_temp_c=finiteNumber(first.temperatureC,ENV_TEMP),width_mm=finiteNumber(first.widthM,0)*1000,
        aspect_ratio=finiteNumber(first.aspectRatio,0),geometry_thermal_scale=1.0,
        warm_reference_ca_factor=finiteNumber(s.warmReferenceCaFactor,0.85),
        relative_warm_ca=finiteNumber(first.relativeWarmCa,1),raw_base_ca=finiteNumber(first.rawBaseCa,1),
        realistic_ca_factor=finiteNumber(first.realisticCaFactor,1),
        arcade_stiffness_authority=finiteNumber(first.arcadeStiffnessAuthority,RT.arcadeHandlingEnabled and 0.60 or 1.0),
        structural_working_temp_c=finiteNumber(s.structuralWorkingTempC,60),
        warm_target_strength=finiteNumber(s.warmCorrectionTargetStrength,1),
        softening_progress=finiteNumber(first.softeningProgress,0),ca_factor=finiteNumber(first.caFactor,1),
        target_tread_scale=finiteNumber(first.targetTreadScale,1),base_applied_tread_scale=finiteNumber(first.baseAppliedTreadScale,finiteNumber(first.appliedTreadScale,1)),applied_tread_scale=finiteNumber(first.appliedTreadScale,1),
        local_structural_delta_c=finiteNumber(first.localStructuralDeltaC,0),local_structural_temp_c=finiteNumber(first.localStructuralTempC,finiteNumber(first.temperatureC,ENV_TEMP)),local_tread_scale_ratio=finiteNumber(first.localTreadScaleRatio,1),local_target_tread_scale=finiteNumber(first.localTargetTreadScale,finiteNumber(first.appliedTreadScale,1)),
        target_tread_damp_scale=finiteNumber(first.targetTreadDampScale,1),applied_tread_damp_scale=finiteNumber(first.appliedTreadDampScale,1),
        stability_model_id=tostring(first.stabilityModelId or (stabilityModel and stabilityModel.id) or "legacy-last-fallback"),
        stability_family_key=tostring(first.stabilityFamilyKey or (stabilityModel and stabilityModel.familyKey) or "unknown"),
        stability_safe_spring_limit=finiteNumber(first.stabilitySafeSpringLimit,1.84),
        stability_summary_wheel_id=tostring(firstId or ""),
        stability_front_safe_spring_limit=frontFamily.safe,stability_rear_safe_spring_limit=rearFamily.safe,
        stability_front_applied_damp_scale=frontFamily.damp,stability_rear_applied_damp_scale=rearFamily.damp,
        stability_front_target_damp_scale=frontFamily.targetDamp,stability_rear_target_damp_scale=rearFamily.targetDamp,
        stability_front_model_id=tostring(frontFamily.model and frontFamily.model.id or "none"),
        stability_rear_model_id=tostring(rearFamily.model and rearFamily.model.id or "none"),
        stability_model_domain_valid=(stabilityModel and stabilityModel.calibrationDomainValid==true) or false,
        stability_model_domain_reason=tostring(stabilityModel and stabilityModel.calibrationDomainReason or "legacy-last-fallback"),
        native_tread_spring=finiteNumber(stabilitySignature and stabilitySignature.avgTreadSpring,0),
        native_tread_damp=finiteNumber(stabilitySignature and stabilitySignature.avgTreadDamp,0),
        structural_support_spring_eq_npm=finiteNumber(stabilityModel and stabilityModel.lastTerms and stabilityModel.lastTerms.supportSpringEqNpm,0),
        structural_fixed_damping_eq=finiteNumber(stabilityModel and stabilityModel.lastTerms and stabilityModel.lastTerms.fixedDampingEq,0),
        structural_budget_npm=finiteNumber(stabilityModel and stabilityModel.lastTerms and stabilityModel.lastTerms.budgetNpm,0),
        structural_zero_damping_capacity_npm=finiteNumber(stabilityModel and stabilityModel.lastTerms and stabilityModel.lastTerms.zeroDampingCapacityNpm,0),
        structural_native_budget_utilization=(stabilityModel and stabilityModel.lastTerms and finiteNumber(stabilityModel.lastTerms.budgetNpm,0)>0)
            and finiteNumber(stabilityModel.lastTerms.nativeLoadNpm,0)/math.max(finiteNumber(stabilityModel.lastTerms.budgetNpm,1),1) or 0,
        damping_prime_hold=first.dampingPrimeHold==true,
        damping_prime_target_spring=finiteNumber(first.dampingPrimeTargetSpring,first.targetTreadScale or 1),
        damping_prime_target_damp=finiteNumber(first.dampingPrimeTargetDamp,first.targetTreadDampScale or 1),
        applied_precompression_scale=finiteNumber(first.appliedPrecompressionScale,1),
        native_topology_epsilon=finiteNumber(first.nativeTopologyEpsilon,0),epsilon_source=first.epsilonSource or "not-captured",
        epsilon_beam_count=finiteNumber(first.epsilonBeamCount,0),epsilon_lower_rejected=finiteNumber(first.epsilonLowerRejected,0),
        precomp_correction_available=first.precompCorrectionAvailable==true,
        epsilon_calibration_phase=tostring(s.calibrationPhase or "WAIT_ASE"),
        ase_detected=s.aseDetected==true,ase_lock_visits=finiteNumber(s.aseLockVisits,0),
        post_ase_settle_age_s=finiteNumber(s.postASESettleAgeS,0),epsilon_controls_locked=s.controlsLocked==true,
        epsilon_export_status=s.lastEpsilonExportStatus or "not-exported",
        epsilon_export_file=s.lastEpsilonExportFile or ""}
end
-- -------------------------------------------------------------------------

-- carcass-supported + geometrically saturating hard-road footprint.
-- See [CP-R1..R3]/[CP-E1..E2] above. This function owns contact AREA only; road
-- heat-transfer coefficient h is resolved separately and receives NO direct PSI multiplier.
local function CalculateGroundContact(loadRaw, pressurePa, tyreWidthM, tyreRadiusM,
                                      sidewallHeightM, liveSidewallSpringScale)
    local mass = math.max(vehicleMass or 1500, 1)
    local wheelCount = math.max(activeWheelCount or 4, 1)
    local nominalWheelLoad = mass * 9.81 / wheelCount
    local load = math.max(finiteNumber(loadRaw, 0), 0)
    local gaugePressure = math.max(finiteNumber(pressurePa, OPTIMAL_PRESSURE), 0)
    local width = clamp(finiteNumber(tyreWidthM, 0.20), 0.05, 0.60)
    local radius = clamp(finiteNumber(tyreRadiusM, 0.33), 0.10, 1.50)
    local sidewallHeight = clamp(finiteNumber(sidewallHeightM, width * M._physicalThermal.contactPatchModel.carcassReferenceAspect),
        0.02, math.max(radius * 0.90, 0.021))
    local aspect = clamp(sidewallHeight / math.max(width, 0.001), 0.20, 1.20)
    local sidewallScale = clamp(finiteNumber(liveSidewallSpringScale, 1.0), 0.40, 2.00)

    -- [CP-R1]+[CP-E1] Pc = c1*Pi + Pcs. The equivalent carcass pressure follows
    -- the already-owned live KTS sidewall stiffness; no second thermal/PSI stiffness model is introduced.
    local aspectScale = clamp((M._physicalThermal.contactPatchModel.carcassReferenceAspect / aspect) ^ M._physicalThermal.contactPatchModel.carcassAspectExponent,
        0.70, 1.45)
    local carcassPressurePa = M._physicalThermal.contactPatchModel.carcassReferencePressurePa * sidewallScale * aspectScale
    local effectiveMeanPressurePa = math.max(
        M._physicalThermal.contactPatchModel.pneumaticPressureCoeff * gaugePressure + carcassPressurePa,
        1000)
    local rawContactPatchArea = load / effectiveMeanPressurePa

    -- [CP-E2] When crown deflection approaches sidewall height, the tyre enters the
    -- collapsed/rim-supported large-deformation regime. Use the corresponding circle
    -- chord as the footprint-length envelope, then a rounded-footprint shape factor.
    local maxDeflection = clamp(sidewallHeight, 0.001, radius * 0.95)
    local maxChordLength = 2 * math.sqrt(math.max(2 * radius * maxDeflection - maxDeflection * maxDeflection, 0))
    local maxContactPatchArea = math.max(width * maxChordLength * M._physicalThermal.contactPatchModel.maxFootprintShapeFactor, 0.005)

    local n = math.max(M._physicalThermal.contactPatchModel.saturationExponent, 1.0)
    local contactPatchArea = 0
    if rawContactPatchArea > 0 and maxContactPatchArea > 0 then
        contactPatchArea = (rawContactPatchArea ^ (-n) + maxContactPatchArea ^ (-n)) ^ (-1 / n)
    end

    local nominalPatchArea = nominalWheelLoad / OPTIMAL_PRESSURE
    local patchRatio = nominalPatchArea > 0 and contactPatchArea / nominalPatchArea or 0

    if patchRatio <= M._physicalThermal.contactPatchModel.deadzoneRatio then
        return 0, contactPatchArea, patchRatio, {
            rawArea = rawContactPatchArea,
            maxArea = maxContactPatchArea,
            effectivePressurePa = effectiveMeanPressurePa,
            carcassPressurePa = carcassPressurePa,
            sidewallScale = sidewallScale,
            aspectRatio = aspect,
            saturationRatio = rawContactPatchArea > 1e-12 and contactPatchArea / rawContactPatchArea or 1,
        }
    end

    local normalizedRatio = clamp(
        (math.min(patchRatio, 1) - M._physicalThermal.contactPatchModel.deadzoneRatio) /
        (1 - M._physicalThermal.contactPatchModel.deadzoneRatio),
        0,
        1
    )
    local contactFactor = math.log(1 + M._physicalThermal.contactPatchModel.logGain * normalizedRatio) /
        math.log(1 + M._physicalThermal.contactPatchModel.logGain)

    if patchRatio > 1 then
        contactFactor = contactFactor + (M._physicalThermal.contactPatchModel.groundCoolingMaxFactor - 1) *
            (1 - math.exp(-(patchRatio - 1)))
    end

    return clamp(contactFactor, 0, M._physicalThermal.contactPatchModel.groundCoolingMaxFactor), contactPatchArea, patchRatio, {
        rawArea = rawContactPatchArea,
        maxArea = maxContactPatchArea,
        effectivePressurePa = effectiveMeanPressurePa,
        carcassPressurePa = carcassPressurePa,
        sidewallScale = sidewallScale,
        aspectRatio = aspect,
        saturationRatio = rawContactPatchArea > 1e-12 and contactPatchArea / rawContactPatchArea or 1,
    }
end

M._userPreferences = M._userPreferences or {
    schema = 1,
    path = "settings/kagoni_tyre_calibration/KTS_user_preferences.json",
    loaded = false,
    wearEnabled = nil,
}
M._userPreferences.schema = 1
M._userPreferences.path = "settings/kagoni_tyre_calibration/KTS_user_preferences.json"

M._userPreferences.load = function(forceDisk)
    local prefs = M._userPreferences
    if not forceDisk and prefs.loaded and prefs.wearEnabled ~= nil then
        tyreWearEnabled = prefs.wearEnabled == true
        return true
    end

    local ok, payload = pcall(function() return jsonReadFile(prefs.path) end)
    if ok and type(payload) == "table" and payload.wear_enabled ~= nil then
        prefs.wearEnabled = payload.wear_enabled == true
    elseif prefs.wearEnabled == nil then
        prefs.wearEnabled = tyreWearEnabled == true
    end
    prefs.loaded = true
    tyreWearEnabled = prefs.wearEnabled == true
    return true
end

M._userPreferences.save = function()
    local prefs = M._userPreferences
    prefs.loaded = true
    prefs.wearEnabled = tyreWearEnabled == true
    if FS and FS.directoryCreate then
        pcall(function() FS:directoryCreate("settings/kagoni_tyre_calibration", true) end)
    end
    local payload = {
        schema = prefs.schema,
        wear_enabled = prefs.wearEnabled,
    }
    local ok, result = pcall(function() return jsonWriteFile(prefs.path, payload, true, 7) end)
    if not ok or result == false then
        log("W", "luukstyrethermalsandwear", "Unable to save KTS user preferences: " .. tostring(result))
        return false
    end
    return true
end

local function setTyreWearEnabled(enabled)
    if type(enabled) == "string" then
        local value = string.lower(enabled)
        enabled = value == "true" or value == "1" or value == "on" or value == "yes"
    else
        enabled = enabled ~= false and enabled ~= 0 and enabled ~= nil
    end

    tyreWearEnabled = enabled
    if M._thermalPause and M._thermalPause.active then
        M._thermalPause.wearBeforePause = tyreWearEnabled
    end
    M._userPreferences.save()
    return tyreWearEnabled
end

local function toggleTyreWear()
    tyreWearEnabled = not tyreWearEnabled
    if M._thermalPause and M._thermalPause.active then
        M._thermalPause.wearBeforePause = tyreWearEnabled
    end
    M._userPreferences.save()
    return tyreWearEnabled
end

M.setArcadeHandlingMode = function(value)
    local enabled = value == true or (tonumber(value) or 0) >= 0.5
    RT.arcadeHandlingEnabled = enabled
    RT.arcadeHandlingRevision = (RT.arcadeHandlingRevision or 0) + 1
    RT.arcadeHandlingLastCommand = enabled and "ARCADE" or "REALISTIC"
    log("I", "luukstyrethermalsandwear",
        "Tyre handling mode switched to " .. RT.arcadeHandlingLastCommand ..
        " revision=" .. tostring(RT.arcadeHandlingRevision) ..
        (enabled and " Arcade2=realistic-mechanics/60%-thermal-penalties" or " full-realistic-severity"))
    return enabled
end

M.toggleArcadeHandlingMode = function()
    return M.setArcadeHandlingMode(not RT.arcadeHandlingEnabled)
end

M._physicalThermal.profileTuningMap = {
    tread_grip_depth_mm = { field = "gripDepthDecayM", scale = 1000 },
    tread_rubber_conductivity = { field = "rubberConductivity", scale = 1 },
    tread_rubber_density = { field = "rubberDensity", scale = 1 },
    tread_rubber_cp = { field = "rubberCp", scale = 1 },
    profile_tread_depth_mm = { field = "treadDepthM", scale = 1000 },
    profile_rolling_resistance = { field = "rollingResistanceCoeff", scale = 1 },
    profile_tread_core_conductance = { field = "skinCoreConductance", scale = 1 },
    profile_slip_heat_partition = { field = "slipHeatPartition", scale = 1 },
    profile_deformation_scale = { field = "deformationScale", scale = 1 },
    profile_core_capacity_scale = { field = "coreCapacityScale", scale = 1 },
    profile_tread_void_ratio = { field = "treadVoidRatio", scale = 1 },
}

M._physicalThermal.getAdvancedProfileKey = function()
    if MANUAL_TYRE_PROFILE == "rally" then
        local _, surface = M._rallyCompounds.getSelected()
        local key = surface and surface.profileId or "rally_asphalt"
        return M._physicalThermal.profiles[key] and key or "rally_asphalt", "manual-rally", false
    end
    if MANUAL_TYRE_PROFILE ~= "auto" then
        local forced = TYRE_PROFILES[MANUAL_TYRE_PROFILE]
        local key = forced and M._physicalThermal.getProfileClassKey(forced) or MANUAL_TYRE_PROFILE
        if M._physicalThermal.profiles[key] then return key, "manual", false end
        return "standard", "manual-fallback", false
    end

    local bestWheelID = nil
    for wheelID in pairs(RT.wheelTyreProfiles or {}) do
        if type(wheelID) == "number" and (bestWheelID == nil or wheelID < bestWheelID) then bestWheelID = wheelID end
    end
    if bestWheelID ~= nil then
        local detected = getWheelTyreProfile(bestWheelID)
        local key = detected and detected.profile and M._physicalThermal.getProfileClassKey(detected.profile) or "standard"
        if M._physicalThermal.profiles[key] then
            local mixed = false
            for wheelID in pairs(RT.wheelTyreProfiles or {}) do
                if type(wheelID) == "number" then
                    local other = getWheelTyreProfile(wheelID)
                    local otherKey = other and other.profile and M._physicalThermal.getProfileClassKey(other.profile) or key
                    if otherKey ~= key then mixed = true; break end
                end
            end
            return key, "auto-wheel:" .. tostring(bestWheelID), mixed
        end
    end
    return "standard", "auto-fallback", false
end

M._physicalThermal.getProfileTuningValue = function(tuningKey, usePreset)
    local map = M._physicalThermal.profileTuningMap[tostring(tuningKey or "")]
    if not map then return nil end
    local profileKey = M._physicalThermal.getAdvancedProfileKey()
    local source = usePreset and M._physicalThermal.profilePresetDefaults or M._physicalThermal.profiles
    local profile = source and source[profileKey] or nil
    if type(profile) ~= "table" then return nil end
    local raw = profile[map.field]
    if raw == nil then
        if map.field == "coreCapacityScale" then raw = 1 end
        if map.field == "treadVoidRatio" then raw = 0 end
    end
    if type(raw) ~= "number" then return nil end
    return raw * (map.scale or 1)
end

M._physicalThermal.setProfileTuningValue = function(tuningKey, value)
    if MANUAL_TYRE_PROFILE == "auto" then return false end
    local map = M._physicalThermal.profileTuningMap[tostring(tuningKey or "")]
    if not map then return false end
    local profileKey = M._physicalThermal.getAdvancedProfileKey()
    local profile = M._physicalThermal.profiles[profileKey]
    if type(profile) ~= "table" then return false end

    local depthHealthBefore = nil
    if map.field == "treadDepthM" then
        depthHealthBefore = {}
        for wheelID, data in pairs(tyreData or {}) do
            local detected = getWheelTyreProfile(wheelID)
            local oldPhysical, oldKey = M._physicalThermal.getPhysicalProfile(detected and detected.profile)
            if oldKey == profileKey then
                depthHealthBefore[wheelID] = M._tread1D.capturePresetDepthHealth(data, oldPhysical)
            end
        end
    end

    profile[map.field] = finiteNumber(value, 0) / (map.scale or 1)

    if depthHealthBefore then
        for wheelID, state in pairs(depthHealthBefore) do
            local data = tyreData and tyreData[wheelID]
            if data then M._tread1D.applyPresetDepthHealth(data, state, profile) end
        end
    end
    return M._physicalThermal.getProfileTuningValue(tuningKey, false)
end

M._physicalThermal.isProfileBoundTuningKey = function(key)
    return M._physicalThermal.profileTuningMap[tostring(key or "")] ~= nil
end

local tuningBindings = {
    experimental_enable_all_spawned_cars = {
        default=0,min=0,max=1,
        get=function() return M._trafficSimulation.enableAllSpawnedCars and 1 or 0 end,
        set=function(value) M.setEnableAllSpawnedCarsLocal(value>=0.5) end,
    },
    experimental_blacklist_current_tyre_id = {
        default=0,min=0,max=1,
        get=function()
            return M._liveStiffnessPopGuard.isCurrentRaceTyreBlacklisted() and 1 or 0
        end,
        set=function(value)
            M._liveStiffnessPopGuard.setCurrentRaceTyreBlacklisted(value>=0.5)
        end,
    },
    sport_physical_stiffness_enabled = {
        default=1,min=0,max=1,
        get=function() return M._sportPhysicalStiffness.enabled and 1 or 0 end,
        set=function(value)
            local requested = value >= 0.5
            if requested and M._liveStiffnessPopGuard and M._liveStiffnessPopGuard.hasActiveBlacklistedTyre then
                local blocked = M._liveStiffnessPopGuard.hasActiveBlacklistedTyre()
                M._sportPhysicalStiffness.enabled = blocked ~= true
            else
                M._sportPhysicalStiffness.enabled = requested
            end
        end,
    },
    sport_stiffness_warm_target_strength = {
        default=1,min=0,max=1.25,
        get=function() return M._sportPhysicalStiffness.warmCorrectionTargetStrength end,
        set=function(value) M._sportPhysicalStiffness.warmCorrectionTargetStrength=clamp(value,0,1.25) end,
    },
    structure_side_spring_scale = {
        default = 1.0, min = 0, max = 2,
        get = function()
            local familySide = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
            return familySide * finiteNumber(M._beamStructureTuner.multipliers.sideSpring, 1.0)
        end,
        set = function(value)
            local familySide = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
            local manual = finiteNumber(value, familySide) / math.max(familySide, 0.000001)
            M._beamStructureTuner.setMultiplier("sideSpring", manual)
        end,
    },
    structure_side_damp_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.sideDamp end,
        set = function(value) M._beamStructureTuner.setMultiplier("sideDamp", value) end,
    },
    structure_side_expansion_spring_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.sideExpansionSpring end,
        set = function(value) M._beamStructureTuner.setMultiplier("sideExpansionSpring", value) end,
    },
    structure_side_expansion_damp_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.sideExpansionDamp end,
        set = function(value) M._beamStructureTuner.setMultiplier("sideExpansionDamp", value) end,
    },
    structure_tread_spring_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.treadSpring end,
        set = function(value) M._beamStructureTuner.setMultiplier("treadSpring", value) end,
    },
    structure_tread_damp_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.treadDamp end,
        set = function(value) M._beamStructureTuner.setMultiplier("treadDamp", value) end,
    },
    structure_side_precompression_scale = {
        default = 1.0, min = 0.8, max = 1.2,
        get = function() return M._beamStructureTuner.multipliers.sidePrecompression end,
        set = function(value) M._beamStructureTuner.setMultiplier("sidePrecompression", value) end,
    },
    structure_tread_precompression_scale = {
        default = 1.0, min = 0.8, max = 1.2,
        get = function() return M._beamStructureTuner.multipliers.treadPrecompression end,
        set = function(value) M._beamStructureTuner.setMultiplier("treadPrecompression", value) end,
    },
    structure_reinf_precompression_scale = {
        default = 1.0, min = 0.8, max = 1.2,
        get = function() return M._beamStructureTuner.multipliers.reinfPrecompression end,
        set = function(value) M._beamStructureTuner.setMultiplier("reinfPrecompression", value) end,
    },
    structure_reinf_spring_scale = {
        default = 1.0, min = 0, max = 2,
        get = function()
            local _, familyReinf = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
            return familyReinf * finiteNumber(M._beamStructureTuner.multipliers.reinfSpring, 1.0)
        end,
        set = function(value)
            local _, familyReinf = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
            local manual = finiteNumber(value, familyReinf) / math.max(familyReinf, 0.000001)
            M._beamStructureTuner.setMultiplier("reinfSpring", manual)
        end,
    },
    structure_reinf_damp_scale = {
        default = 1.0, min = 0, max = 2,
        get = function() return M._beamStructureTuner.multipliers.reinfDamp end,
        set = function(value) M._beamStructureTuner.setMultiplier("reinfDamp", value) end,
    },
    arcade_handling_mode_enabled = {
        default = 0, min = 0, max = 1,
        get = function() return RT.arcadeHandlingEnabled and 1 or 0 end,
        set = function(value) M.setArcadeHandlingMode(value) end,
    },
    repeated_test_thermal_cap_enabled = {
        default = 0, min = 0, max = 1,
        get = function() return M._repeatedTestThermalCap.enabled and 1 or 0 end,
        set = function(value)
            M._repeatedTestThermalCap.enabled = value >= 0.5
            M._repeatedTestThermalCap.applyCaps()
        end,
    },
    baseline_grip_uplift_enabled = {
        default = 1, min = 0, max = 1,
        get = function() return M._baselineGripUplift.enabled and 1 or 0 end,
        set = function(value) M._baselineGripUplift.enabled = value >= 0.5 end,
    },
    baseline_uplift_standard = {
        default = 0.98, min = 0.70, max = 1.35,
        get = function() return M._baselineGripUplift.profileMultipliers.standard end,
        set = function(value) M._baselineGripUplift.profileMultipliers.standard = value end,
    },
    baseline_uplift_sport = {
        default = 1.01, min = 0.70, max = 1.35,
        get = function() return M._baselineGripUplift.profileMultipliers.sport end,
        set = function(value) M._baselineGripUplift.profileMultipliers.sport = value end,
    },
    baseline_uplift_semi_slick = {
        default = 1.02, min = 0.70, max = 1.35,
        get = function() return M._baselineGripUplift.profileMultipliers.semi_slick end,
        set = function(value) M._baselineGripUplift.profileMultipliers.semi_slick = value end,
    },
    baseline_uplift_race = {
        default = 1.00, min = 0.70, max = 1.35,
        get = function() return M._baselineGripUplift.profileMultipliers.race end,
        set = function(value) M._baselineGripUplift.profileMultipliers.race = value end,
    },
    baseline_uplift_rally_asphalt = {
        default = 1.00, min = 1.0, max = 1.10,
        get = function()
            local surface = M._rallyCompounds and M._rallyCompounds.surfaces
                and M._rallyCompounds.surfaces.asphalt
            return surface and surface.roadPeakMultiplier or 1.00
        end,
        set = function(value)
            local surface = M._rallyCompounds and M._rallyCompounds.surfaces
                and M._rallyCompounds.surfaces.asphalt
            if surface then surface.roadPeakMultiplier = clamp(finiteNumber(value, 1.00), 1.00, 1.10) end
        end,
    },
    baseline_uplift_rally_gravel = {
        default = 1.08, min = 1.0, max = 1.10,
        get = function()
            local surface = M._rallyCompounds and M._rallyCompounds.surfaces
                and M._rallyCompounds.surfaces.gravel
            return surface and surface.roadPeakMultiplier or 1.08
        end,
        set = function(value)
            local surface = M._rallyCompounds and M._rallyCompounds.surfaces
                and M._rallyCompounds.surfaces.gravel
            if surface then surface.roadPeakMultiplier = clamp(finiteNumber(value, 1.08), 1.00, 1.10) end
        end,
    },
    baseline_uplift_drift = {
        default = 1.00, min = 1.0, max = 1.35,
        get = function() return M._baselineGripUplift.profileMultipliers.drift end,
        set = function(value) M._baselineGripUplift.profileMultipliers.drift = value end,
    },
    cool_slide_floor_standard = {
        default = 0.86, min = 0.50, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.standard end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.standard = value end,
    },
    cool_slide_floor_sport = {
        default = 0.90, min = 0.50, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.sport end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.sport = value end,
    },
    cool_slide_floor_race = {
        default = 0.86, min = 0.50, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.race end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.race = value end,
    },
    cool_slide_floor_rally_asphalt = {
        default = 0.89, min = 0.50, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.rally_asphalt end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.rally_asphalt = value end,
    },
    cool_slide_floor_rally_gravel = {
        default = 0.84, min = 0.50, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.rally_gravel end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.rally_gravel = value end,
    },
    cool_slide_floor_drift = {
        default = 0.00, min = 0.00, max = 1.20,
        get = function() return M._slipPlateau.coolFullSlideRatioByProfile.drift end,
        set = function(value) M._slipPlateau.coolFullSlideRatioByProfile.drift = value end,
    },
    hot_slide_floor_drift = {
        default = 0.00, min = 0.00, max = 1.20,
        get = function() return M._slipPlateau.hotFullSlideRatioByProfile.drift end,
        set = function(value) M._slipPlateau.hotFullSlideRatioByProfile.drift = value end,
    },
    surface_heat_memory_enabled = {
        default = 1, min = 0, max = 1,
        get = function() return M._slipPlateau.surfaceHeatEnabled and 1 or 0 end,
        set = function(value)
            M._slipPlateau.surfaceHeatEnabled = value >= 0.5
            wheelFlashGripState = {}
        end,
    },
    tread_grip_depth_mm = {
        default = 0.80, min = 0.10, max = 4.00,
        get = function() return M._physicalThermal.getProfileTuningValue("tread_grip_depth_mm", false) or 0.80 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("tread_grip_depth_mm", value) end,
    },
    tread_rubber_conductivity = {
        default = 0.235, min = 0.05, max = 1.00,
        get = function() return M._physicalThermal.getProfileTuningValue("tread_rubber_conductivity", false) or 0.235 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("tread_rubber_conductivity", value) end,
    },
    tread_rubber_density = {
        default = 1125, min = 700, max = 1500,
        get = function() return M._physicalThermal.getProfileTuningValue("tread_rubber_density", false) or 1125 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("tread_rubber_density", value) end,
    },
    tread_rubber_cp = {
        default = 1590, min = 800, max = 3000,
        get = function() return M._physicalThermal.getProfileTuningValue("tread_rubber_cp", false) or 1590 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("tread_rubber_cp", value) end,
    },
    profile_tread_depth_mm = {
        default = 9.5, min = 1.0, max = 20.0,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_tread_depth_mm", false) or 9.5 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_tread_depth_mm", value) end,
    },
    profile_rolling_resistance = {
        default = 0.0120, min = 0.001, max = 0.050,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_rolling_resistance", false) or 0.0120 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_rolling_resistance", value) end,
    },
    profile_tread_core_conductance = {
        default = 75.0, min = 1.0, max = 400.0,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_tread_core_conductance", false) or 75.0 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_tread_core_conductance", value) end,
    },
    profile_slip_heat_partition = {
        default = 0.30, min = 0.00, max = 1.00,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_slip_heat_partition", false) or 0.30 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_slip_heat_partition", value) end,
    },
    profile_deformation_scale = {
        default = 1.00, min = 0.10, max = 3.00,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_deformation_scale", false) or 1.00 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_deformation_scale", value) end,
    },
    profile_core_capacity_scale = {
        default = 1.00, min = 0.50, max = 2.00,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_core_capacity_scale", false) or 1.00 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_core_capacity_scale", value) end,
    },
    profile_tread_void_ratio = {
        default = 0.35, min = 0.00, max = 0.60,
        get = function() return M._physicalThermal.getProfileTuningValue("profile_tread_void_ratio", false) or 0.35 end,
        set = function(value) M._physicalThermal.setProfileTuningValue("profile_tread_void_ratio", value) end,
    },
    cross_tread_research_enabled = {
        default = 1, min = 0, max = 1,
        get = function() return M._crossTreadResearch.enabled and 1 or 0 end,
        set = function(value) M._crossTreadResearch.enabled = value >= 0.5 end,
    },
    cross_tread_pressure_shape_gain = {
        default = 0.75, min = 0.00, max = 1.50,
        get = function() return M._crossTreadResearch.pressureShapeGain end,
        set = function(value) M._crossTreadResearch.pressureShapeGain = value end,
    },
    cross_tread_pressure_exponent = {
        default = 0.95, min = 0.00, max = 2.00,
        get = function() return M._crossTreadResearch.pressureRatioExponent end,
        set = function(value) M._crossTreadResearch.pressureRatioExponent = value end,
    },
    cross_tread_load_exponent = {
        default = 0.65, min = 0.00, max = 1.50,
        get = function() return M._crossTreadResearch.loadRatioExponent end,
        set = function(value) M._crossTreadResearch.loadRatioExponent = value end,
    },
    cross_tread_flex_edge_gain = {
        default = 0.65, min = 0.00, max = 2.00,
        get = function() return M._crossTreadResearch.flexEdgeGain end,
        set = function(value) M._crossTreadResearch.flexEdgeGain = value end,
    },
    cross_tread_flex_compliance_exponent = {
        default = 1.00, min = 0.00, max = 2.00,
        get = function() return M._crossTreadResearch.flexComplianceExponent end,
        set = function(value) M._crossTreadResearch.flexComplianceExponent = value end,
    },
    cross_tread_crown_support_sport = {
        default = 0.80, min = 0.00, max = 4.00,
        get = function() return M._crossTreadResearch.crownSupportRatioByProfile.sport end,
        set = function(value) M._crossTreadResearch.crownSupportRatioByProfile.sport = value end,
    },
    cross_tread_crown_support_race = {
        default = 2.00, min = 0.00, max = 5.00,
        get = function() return M._crossTreadResearch.crownSupportRatioByProfile.race end,
        set = function(value) M._crossTreadResearch.crownSupportRatioByProfile.race = value end,
    },
    thin_surface_road_scale = {
        default = 0.50, min = 0.00, max = 2.00,
        get = function() return M._physicalThermal.thinSurfaceRoadConductanceScale end,
        set = function(value) M._physicalThermal.thinSurfaceRoadConductanceScale = value end,
    },
    flash_to_surface_conductance = {
        default = 4.0, min = 0.0, max = 25.0,
        get = function() return M._physicalThermal.flashToSurfaceConductance end,
        set = function(value) M._physicalThermal.flashToSurfaceConductance = value end,
    },
    flash_input_fraction = {
        default = 0.10, min = 0.01, max = 0.50,
        get = function() return M._physicalThermal.flashInputFraction end,
        set = function(value) M._physicalThermal.flashInputFraction = value end,
    },
    flash_retained_share = {
        default = 0.20, min = 0.00, max = 0.75,
        get = function() return M._physicalThermal.flashMaxRetainedTyreShare end,
        set = function(value) M._physicalThermal.flashMaxRetainedTyreShare = value end,
    },
    working_temp_c = {
        default = -1, min = -1, max = 250,
        get = function() return WORKING_TEMP end,
        set = function(value)
            WORKING_TEMP = value
        end,
    },
    hot_grip_loss_factor = {
        default = 1.0, min = 0, max = 50,
        get = function() return HOT_GRIP_LOSS_FACTOR end,
        set = function(value) HOT_GRIP_LOSS_FACTOR = value end,
    },
    flash_micro_temp_sensitivity = {
        default = 0.15, min = 0, max = 2.0,
        get = function() return M._flashMemory.flashLocalToBulkEquivalentScale end,
        set = function(value) M._flashMemory.flashLocalToBulkEquivalentScale = value end,
    },
    pressurewheel_brush_enabled = {
        default = 1, min = 0, max = 1,
        get = function() return M._pressureWheelBrush.enabled and 1 or 0 end,
        set = function(value)
            M._pressureWheelBrush.enabled = value >= 0.5
            wheelFlashGripState = {}
        end,
    },
    pressurewheel_brush_strength = {
        default = 1.00, min = 0, max = 1.50,
        get = function() return M._pressureWheelBrush.strength end,
        set = function(value) M._pressureWheelBrush.strength = value end,
    },
    pressurewheel_sidewall_exponent = {
        default = 1.00, min = 0, max = 1.50,
        get = function() return M._pressureWheelBrush.sidewallAspectExponent end,
        set = function(value) M._pressureWheelBrush.sidewallAspectExponent = value end,
    },
    pressurewheel_pressure_exponent = {
        default = 0.25, min = 0, max = 1.00,
        get = function() return M._pressureWheelBrush.livePressureExponent end,
        set = function(value) M._pressureWheelBrush.livePressureExponent = value end,
    },
    pressurewheel_width_exponent = {
        default = 0.10, min = 0, max = 0.75,
        get = function() return M._pressureWheelBrush.widthExponent end,
        set = function(value) M._pressureWheelBrush.widthExponent = value end,
    },
    pressurewheel_jbeam_influence = {
        default = 0.18, min = 0, max = 1.00,
        get = function() return M._pressureWheelBrush.jbeamStructureInfluence end,
        set = function(value) M._pressureWheelBrush.jbeamStructureInfluence = value end,
    },
    pressurewheel_type_standard = {
        default = 1.00, min = 0.40, max = 2.50,
        get = function() return M._pressureWheelBrush.profileTypeStiffness.standard end,
        set = function(value) M._pressureWheelBrush.profileTypeStiffness.standard = value end,
    },
    pressurewheel_type_sport = {
        default = 1.00, min = 0.40, max = 2.50,
        get = function() return M._pressureWheelBrush.profileTypeStiffness.sport end,
        set = function(value) M._pressureWheelBrush.profileTypeStiffness.sport = value end,
    },
    pressurewheel_type_race = {
        default = 1.00, min = 0.40, max = 2.50,
        get = function() return M._pressureWheelBrush.profileTypeStiffness.race end,
        set = function(value) M._pressureWheelBrush.profileTypeStiffness.race = value end,
    },
    pressurewheel_type_drift = {
        default = 1.00, min = 0.40, max = 2.50,
        get = function() return M._pressureWheelBrush.profileTypeStiffness.drift end,
        set = function(value) M._pressureWheelBrush.profileTypeStiffness.drift = value end,
    },
    cornering_heat_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return TEMP_WORK_GAIN_RATE end,
        set = function(value) TEMP_WORK_GAIN_RATE = value end,
    },
    slip_heat_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return TEMP_SLIP_GAIN_RATE end,
        set = function(value) TEMP_SLIP_GAIN_RATE = value end,
    },
    ambient_skin_cooling_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return TEMP_COOL_RATE end,
        set = function(value) TEMP_COOL_RATE = value end,
    },
    speed_skin_cooling_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return TEMP_COOL_VEL_RATE end,
        set = function(value) TEMP_COOL_VEL_RATE = value end,
    },
    brake_to_core_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return TEMP_GAIN_RATE_CORE end,
        set = function(value) TEMP_GAIN_RATE_CORE = value end,
    },
    wear_rate = {
        default = 1.0, min = 0, max = 10,
        get = function() return WEAR_RATE end,
        set = function(value) WEAR_RATE = value end,
    },
    ground_cooling_strength_percent = {
        default = 1.0, min = 0.01, max = 10.0,
        get = function() return GROUND_COOLING_SCALE end,
        set = function(value) GROUND_COOLING_SCALE = value end,
    },
    grass_ground_cooling_strength_percent = {
        default = 10.0, min = 0.01, max = 50.0,
        get = function() return GRASS_GROUND_COOLING_SCALE end,
        set = function(value) GRASS_GROUND_COOLING_SCALE = value end,
    },
    grass_slip_heat_rate = {
        default = 0.1666666666666667, min = 0, max = 16.6666666666667,
        get = function() return GRASS_SLIP_HEAT_RATE end,
        set = function(value) GRASS_SLIP_HEAT_RATE = value end,
    },
    water_cooling_multiplier = {
        default = 30.0, min = 0, max = 1000,
        get = function() return WATER_COOLING_MULTIPLIER end,
        set = function(value) WATER_COOLING_MULTIPLIER = value end,
    },
    contact_patch_log_gain = {
        default = 100000, min = 0.000001, max = 1000000000,
        get = function() return M._physicalThermal.contactPatchModel.logGain end,
        set = function(value) M._physicalThermal.contactPatchModel.logGain = value end,
    },
    contact_patch_deadzone_percent = {
        default = 0.2, min = 0, max = 50,
        get = function() return M._physicalThermal.contactPatchModel.deadzoneRatio * 100 end,
        set = function(value) M._physicalThermal.contactPatchModel.deadzoneRatio = value / 100 end,
    },
    ground_cooling_max_factor = {
        default = 1.35, min = 0, max = 10,
        get = function() return M._physicalThermal.contactPatchModel.groundCoolingMaxFactor end,
        set = function(value) M._physicalThermal.contactPatchModel.groundCoolingMaxFactor = value end,
    },
    locked_patch_flash_grip_enabled = {
        default = 1, min = 0, max = 1,
        get = function() return RT.lockedPatchFlashGripEnabled and 1 or 0 end,
        set = function(value)
            RT.lockedPatchFlashGripEnabled = value >= 0.5
            if not RT.lockedPatchFlashGripEnabled then
                wheelFlashGripState = {}
            end
        end,
    },
}

local AUTO_THERMAL_PRESET_TUNING_KEYS = {
    ground_cooling_strength_percent = true,
    grass_ground_cooling_strength_percent = true,
    grass_slip_heat_rate = true,
    water_cooling_multiplier = true,
    contact_patch_log_gain = true,
    contact_patch_deadzone_percent = true,
    ground_cooling_max_factor = true,
}

local AUTO_FULL_SLIDE_TUNING_KEYS = {
    cool_slide_floor_standard = true,
    cool_slide_floor_sport = true,
    cool_slide_floor_race = true,
    cool_slide_floor_rally_asphalt = true,
    cool_slide_floor_rally_gravel = true,
    cool_slide_floor_drift = true,
}

local AUTO_FAMILY_STRUCTURE_TUNING_KEYS = {
    structure_side_spring_scale = true,
    structure_reinf_spring_scale = true,
}

local function isAutoPresetLockedTuningKey(key)
    key = tostring(key or "")
    return M._physicalThermal.isProfileBoundTuningKey(key)
        or AUTO_THERMAL_PRESET_TUNING_KEYS[key] == true
        or AUTO_FULL_SLIDE_TUNING_KEYS[key] == true
        or AUTO_FAMILY_STRUCTURE_TUNING_KEYS[key] == true
end

local function getTuningValues()
    local values = {}
    for key, binding in pairs(tuningBindings) do
        values[key] = binding.get()
    end
    return values
end

local function getTuningNativeValues()
    local values = {}
    local preset = THERMAL_PRESETS[ACTIVE_THERMAL_PRESET] or THERMAL_PRESETS.general
    local presetValues = preset.values or {}
    for key, binding in pairs(tuningBindings) do
        local value
        if M._physicalThermal.isProfileBoundTuningKey(key) then
            value = M._physicalThermal.getProfileTuningValue(key, true)
        elseif AUTO_FAMILY_STRUCTURE_TUNING_KEYS[key] == true then
            local familySide, familyReinf = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
            value = key == "structure_side_spring_scale" and familySide or familyReinf
        else
            value = presetValues[key]
        end
        if value == nil then value = binding.default end
        values[key] = value
    end
    return values
end

local function setTuningValue(key, value)
    local binding = tuningBindings[tostring(key or "")]
    value = tonumber(value)
    if not binding or not value or value ~= value or value == math.huge or value == -math.huge then
        return false
    end
    if MANUAL_TYRE_PROFILE == "auto" and isAutoPresetLockedTuningKey(key) then
        return false
    end

    value = clamp(value, binding.min, binding.max)
    binding.set(value)

    if tostring(key or "") == "experimental_enable_all_spawned_cars" and obj and obj.queueGameEngineLua then
        local enabledLiteral = value >= 0.5 and "true" or "false"
        obj:queueGameEngineLua(
            "local e=(extensions and extensions.luukstyrethermalsandwear) or luukstyrethermalsandwear; if e and e.setEnableAllSpawnedCars then e.setEnableAllSpawnedCars(" .. enabledLiteral .. ") end"
        )
    end
    return binding.get()
end

local function resetTuningValue(key)
    key = tostring(key or "")
    local binding = tuningBindings[key]
    if not binding then return false end
    if key == "experimental_enable_all_spawned_cars" then
        return setTuningValue(key, binding.default)
    end
    if key == "experimental_blacklist_current_tyre_id" then
        -- Persistent blacklist membership changes only through an explicit checkbox
        -- action; a generic tuning reset must not silently erase a learned safety ID.
        return binding.get()
    end
    local preset = THERMAL_PRESETS[ACTIVE_THERMAL_PRESET] or THERMAL_PRESETS.general
    local presetValue
    if M._physicalThermal.isProfileBoundTuningKey(key) then
        if MANUAL_TYRE_PROFILE == "auto" then return binding.get() end
        presetValue = M._physicalThermal.getProfileTuningValue(key, true)
    elseif AUTO_FAMILY_STRUCTURE_TUNING_KEYS[key] == true then
        if MANUAL_TYRE_PROFILE == "auto" then return binding.get() end
        local familySide, familyReinf = M._sportPhysicalStiffness.getAdvancedFamilyBaseStructure()
        presetValue = key == "structure_side_spring_scale" and familySide or familyReinf
    else
        if MANUAL_TYRE_PROFILE == "auto" and (AUTO_THERMAL_PRESET_TUNING_KEYS[key] == true or AUTO_FULL_SLIDE_TUNING_KEYS[key] == true) then
            return binding.get()
        end
        presetValue = preset.values[key]
    end
    binding.set(presetValue ~= nil and presetValue or binding.default)
    return binding.get()
end

local function resetAllTuningValues()
    applyThermalPresetValues(ACTIVE_THERMAL_PRESET)
    M._repeatedTestThermalCap.enabled = false
    M.setArcadeHandlingMode(false)
    setTuningValue("experimental_enable_all_spawned_cars", 0)
    RT.lockedPatchFlashGripEnabled = true
    M._pressureWheelBrush.enabled = true
    M._pressureWheelBrush.dynamicFialaEnabled = true
    M._pressureWheelBrush.corneringStiffnessPeakLoadRatio = 3.0
    M._pressureWheelBrush.dynamicLoadFilterTauS = 0.045
    M._pressureWheelBrush.minCriticalAngleDeg = 3.0
    M._pressureWheelBrush.strength = 1.00
    M._pressureWheelBrush.sidewallAspectExponent = 1.00
    M._pressureWheelBrush.livePressureExponent = 0.25
    M._pressureWheelBrush.widthExponent = 0.10
    M._pressureWheelBrush.jbeamStructureInfluence = 0.18
    M._pressureWheelBrush.profileTypeStiffness.standard = 1.00
    M._pressureWheelBrush.profileTypeStiffness.sport = 1.00
    M._pressureWheelBrush.profileTypeStiffness.race = 1.00
    M._pressureWheelBrush.profileTypeStiffness.rally_asphalt = 1.00
    M._pressureWheelBrush.profileTypeStiffness.rally_gravel = 0.88
    M._pressureWheelBrush.profileTypeStiffness.drift = 1.00
    M._baselineGripUplift.enabled = true
    M._baselineGripUplift.profileMultipliers.standard = 1.00
    M._baselineGripUplift.profileMultipliers.sport = 1.01
    M._baselineGripUplift.profileMultipliers.semi_slick = 1.02
    M._baselineGripUplift.profileMultipliers.race = 1.00
    M._baselineGripUplift.profileMultipliers.rally_asphalt = 1.00
    M._baselineGripUplift.profileMultipliers.rally_gravel = 1.00
    if M._rallyCompounds and M._rallyCompounds.surfaces then
        if M._rallyCompounds.surfaces.asphalt then
            M._rallyCompounds.surfaces.asphalt.roadPeakMultiplier = 1.00
        end
        if M._rallyCompounds.surfaces.gravel then
            M._rallyCompounds.surfaces.gravel.roadPeakMultiplier = 1.08
        end
    end
    M._baselineGripUplift.profileMultipliers.drift = 1.00
    M._slipPlateau.enabled = true
    M._slipPlateau.surfaceHeatEnabled = true
    M._slipPlateau.coolFullSlideRatioByProfile.standard = 0.88
    M._slipPlateau.coolFullSlideRatioByProfile.sport = 0.90
    M._slipPlateau.coolFullSlideRatioByProfile.race = 0.86
    M._slipPlateau.coolFullSlideRatioByProfile.rally_asphalt = 0.89
    M._slipPlateau.coolFullSlideRatioByProfile.rally_gravel = 0.84
    M._slipPlateau.coolFullSlideRatioByProfile.drift = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.standard = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.sport = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.race = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.rally_asphalt = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.rally_gravel = 0.00
    M._slipPlateau.hotFullSlideRatioByProfile.drift = 0.00
    M._slipPlateau.profileThermalCurveSlideByProfile.standard = true
    M._slipPlateau.profileThermalCurveSlideByProfile.sport = true
    M._slipPlateau.profileThermalCurveSlideByProfile.race = true
    M._slipPlateau.profileThermalCurveSlideByProfile.rally_asphalt = true
    M._slipPlateau.profileThermalCurveSlideByProfile.rally_gravel = true
    M._slipPlateau.profileThermalCurveSlideByProfile.drift = true
    M._tread1D.gripDepthDecayM = 0.00065
    M._physicalThermal.resetAllProfilesToPreset()
    M._crossTreadResearch.enabled = true
    M._crossTreadResearch.pressureShapeGain = 0.75
    M._crossTreadResearch.pressureRatioExponent = 0.95
    M._crossTreadResearch.loadRatioExponent = 0.65
    M._crossTreadResearch.flexEdgeGain = 0.65
    M._crossTreadResearch.flexComplianceExponent = 1.00
    M._crossTreadResearch.crownSupportRatioByProfile.standard = 0.00
    M._crossTreadResearch.crownSupportRatioByProfile.sport = 0.80
    M._crossTreadResearch.crownSupportRatioByProfile.race = 2.00
    M._crossTreadResearch.crownSupportRatioByProfile.rally_asphalt = 1.25
    M._crossTreadResearch.crownSupportRatioByProfile.rally_gravel = 0.55
    M._crossTreadResearch.crownSupportRatioByProfile.drift = 0.00
    M._physicalThermal.thinSurfaceRoadConductanceScale = 0.50
    M._physicalThermal.flashToSurfaceConductance = 4.0
    M._physicalThermal.flashInputFraction = 0.10
    M._physicalThermal.flashMaxRetainedTyreShare = 0.20
    M._flashMemory.flashLocalToBulkEquivalentScale = 0.15
    wheelFlashGripState = {}
    M._beamStructureTuner.resetMultipliers()
    return getTuningValues()
end

GetGroundModelData = function(id)
    local materials, materialsMap = particles.getMaterialsParticlesTable()
    local matData = materials[id] or {}
    local name = matData.name or "DOESNT EXIST"
    local data = groundModels[name]
        or groundModels[string.lower(tostring(name))]
        or groundModels[string.upper(tostring(name))]
        or { staticFrictionCoefficient = 1, slidingFrictionCoefficient = 1 }
    return name, data
end

local function IsGrassSurface(name)
    local normalized = string.lower(tostring(name or "")):gsub("[%s%-]+", "_")
    return string.find(normalized, "grass", 1, true) ~= nil
        or string.find(normalized, "lawn", 1, true) ~= nil
        or string.find(normalized, "turf", 1, true) ~= nil
end

M._rallyDirt.normalizeSurfaceName = function(name)
    return string.lower(tostring(name or "")):gsub("[%s%-%/]+", "_")
end

M._rallyDirt.classifySurface = function(name, groundModel)
    local normalized = M._rallyDirt.normalizeSurfaceName(name)
    local function has(token)
        return string.find(normalized, token, 1, true) ~= nil
    end

    if has("mud") or has("swamp") or has("bog") then return "mud" end
    if (has("packed") or has("compacted") or has("hardpack"))
        and (has("gravel") or has("dirt") or has("soil")) then
        return "packed_gravel"
    end
    if has("rocky") or has("bedrock") or has("stone_road")
        or ((has("rock") or has("stone")) and not has("cobble")) then
        return "packed_gravel"
    end
    if has("gravel") or has("loose_rock") or has("pebble") or has("shingle") then
        return "loose_gravel"
    end
    if has("dirt_road") or has("forest_road") or has("sandy_road") then
        return "packed_gravel"
    end
    if has("dirt") or has("soil") or has("clay") or has("sand") or has("beach")
        or has("forest") or has("trail") or has("offroad") or has("off_road")
        or has("grass") or has("lawn") or has("turf")
        or has("snow") or has("ice") then
        return "dirt"
    end
    if has("asphalt") or has("tarmac") or has("concrete") or has("pavement")
        or has("cobble") or has("brick") or has("road") then
        return "road"
    end

    local gm = type(groundModel) == "table" and groundModel or {}
    local depth = math.max(finiteNumber(gm.defaultDepth, 0), 0)
    local fluidDensity = math.max(finiteNumber(gm.fluidDensity, 0), 0)
    local hydro = math.max(finiteNumber(gm.hydrodynamicFriction, 0), 0)
    local roughness = math.max(finiteNumber(gm.roughnessCoefficient, 0), 0)
    local strength = math.max(finiteNumber(gm.strength, 0), 0)
    if fluidDensity > 50 or hydro > 0.01 then return "mud" end
    if depth > 0.018 then return "dirt" end
    if depth > 0.003 and (roughness > 0.25 or strength > 0.5) then return "packed_gravel" end
    if depth > 0.003 or roughness > 0.10 then return "dirt" end
    return "unknown"
end

M._rallyDirt.classifyPair = function(primaryName, primaryModel, secondaryName, secondaryModel, fallback)
    local first = M._rallyDirt.classifySurface(primaryName, primaryModel)
    local second = M._rallyDirt.classifySurface(secondaryName, secondaryModel)
    local firstCfg = M._rallyDirt.surfaces[first]
    local secondCfg = M._rallyDirt.surfaces[second]
    if firstCfg and secondCfg then
        return finiteNumber(firstCfg.priority, 0) >= finiteNumber(secondCfg.priority, 0) and first or second
    end
    if firstCfg then return first end
    if secondCfg then return second end
    if first == "road" or second == "road" then return "road" end
    return M._rallyDirt.surfaces[fallback] and fallback or "road"
end

M._rallyDirt.classifyMaterialID = function(materialID)
    local id = tonumber(materialID)
    if id == nil or id < 0 then return "unknown", "DOESNT EXIST", nil end
    local cached = M._rallyDirt.materialClassCache[id]
    if type(cached) == "table" then return cached.class, cached.name, cached.model end
    local name, model = GetGroundModelData(id)
    local class = M._rallyDirt.classifySurface(name, model)
    M._rallyDirt.materialClassCache[id] = {class = class, name = name, model = model}
    return class, name, model
end

M._rallyDirt.classifyWheelNow = function(wheelID, fallback)
    local wd = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    if not wd then return fallback or "road", "none" end
    local id1 = tonumber(wd.contactMaterialID1) or -1
    local id2 = tonumber(wd.contactMaterialID2) or -1
    local _, name1, model1 = M._rallyDirt.classifyMaterialID(id1)
    local _, name2, model2 = M._rallyDirt.classifyMaterialID(id2)
    local class = M._rallyDirt.classifyPair(name1, model1, name2, model2, fallback)
    return class, tostring(id1) .. ":" .. tostring(id2)
end

M._rallyDirt.isRallyProfile = function(profile)
    local id = type(profile) == "table" and tostring(profile.id or "") or tostring(profile or "")
    return id == "rally_asphalt" or id == "rally_gravel"
end

M._rallyDirt.getSurfaceModel = function(surfaceClass)
    return M._rallyDirt.surfaces[surfaceClass]
end

M._rallyDirt.ensureBlockEdges = function(data)
    if type(data) ~= "table" then return nil end
    data.rally_block_edges = type(data.rally_block_edges) == "table" and data.rally_block_edges or {}
    for zone = 1, 3 do
        local edge = type(data.rally_block_edges[zone]) == "table" and data.rally_block_edges[zone] or {}
        edge.xp = clamp(finiteNumber(edge.xp, 1), 0, 1)
        edge.xn = clamp(finiteNumber(edge.xn, 1), 0, 1)
        edge.yp = clamp(finiteNumber(edge.yp, 1), 0, 1)
        edge.yn = clamp(finiteNumber(edge.yn, 1), 0, 1)
        data.rally_block_edges[zone] = edge
    end
    return data.rally_block_edges
end

M._rallyDirt.getDirectionState = function(wheelID)
    local cache = wheelCache[wheelID] or {}
    local signedX = finiteNumber(cache.signedLongitudinalSlipSpeed, cache.longitudinalSlipSpeed or 0)
    local signedY = finiteNumber(cache.signedLateralSlipSpeed, cache.lateralSlipSpeed or 0)
    local x2 = signedX * signedX
    local y2 = signedY * signedY
    local sum = x2 + y2
    local wx = sum > 1e-8 and x2 / sum or 0.5
    return wx, 1 - wx, signedX >= 0 and "xp" or "xn", signedY >= 0 and "yp" or "yn"
end

M._rallyDirt.getBlockTemperatureC = function(data)
    if type(data) ~= "table" then return ENV_TEMP end
    local weights = type(data.contact_zone_weights) == "table" and data.contact_zone_weights or {1 / 3, 1 / 3, 1 / 3}
    local total, weightSum = 0, 0
    for zone = 1, 3 do
        local field = type(data.tread_field) == "table" and data.tread_field[zone] or nil
        local surface = finiteNumber(data.surface_temp and data.surface_temp[zone], ENV_TEMP)
        local depth = finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[zone], 0.006)
        local simDepth = math.max(depth, M._tread1D.minimumSimDepthM)
        local near = M._tread1D.getDepthIntervalAverage(field, simDepth, 0.0, 1/3, surface)
        local middle = M._tread1D.getDepthIntervalAverage(field, simDepth, 1/3, 2/3, near)
        local deep = M._tread1D.getDepthIntervalAverage(field, simDepth, 2/3, 1.0, middle)
        local zoneTemp = 0.05 * surface + 0.55 * near + 0.30 * middle + 0.10 * deep
        local weight = clamp(finiteNumber(weights[zone], 1 / 3), 0, 1)
        total = total + zoneTemp * weight
        weightSum = weightSum + weight
    end
    return total / math.max(weightSum, 1e-6)
end

M._rallyDirt.getCompoundWindow = function()
    local selected = tostring(M._rallyCompounds.selectedCompound or "medium")
    return M._rallyDirt.compoundWindows[selected] or M._rallyDirt.compoundWindows.medium
end

M._rallyDirt.getTemperatureGrip = function(data, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if not cfg then return 1, ENV_TEMP end
    local blockTemp = M._rallyDirt.getBlockTemperatureC(data)
    local window = M._rallyDirt.getCompoundWindow()
    local low, high = finiteNumber(window[1], 70), finiteNumber(window[2], 130)
    local value
    if blockTemp < low - 50 then
        value = cfg.coldGrip
    elseif blockTemp < low then
        value = cfg.coldGrip + (1 - cfg.coldGrip) * ((blockTemp - (low - 50)) / 50)
    elseif blockTemp <= high then
        value = 1
    elseif blockTemp < high + 60 then
        value = 1 + (cfg.hot60Grip - 1) * ((blockTemp - high) / 60)
    elseif blockTemp < high + 130 then
        value = cfg.hot60Grip + (cfg.hot130Grip - cfg.hot60Grip) * ((blockTemp - high - 60) / 70)
    else
        value = cfg.hot130Grip
    end
    value = M._arcadeHandling.applyThermalPenalty(clamp(value, 0.05, 1.0))
    return value, blockTemp
end

M._rallyDirt.getWearTemperatureMultiplier = function(tempC, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if not cfg then return 1 end
    local window = M._rallyDirt.getCompoundWindow()
    local high = finiteNumber(window[2], 130)
    local over = math.max(finiteNumber(tempC, high) - high, 0)
    if over <= 20 then return 1 end
    if over < 60 then
        return 1 + (finiteNumber(cfg.hotWear60, 1.1) - 1) * ((over - 20) / 40)
    end
    if over < 130 then
        return finiteNumber(cfg.hotWear60, 1.1)
            + (finiteNumber(cfg.hotWear130, 1.4) - finiteNumber(cfg.hotWear60, 1.1))
                * ((over - 60) / 70)
    end
    return finiteNumber(cfg.hotWear130, 1.4)
end

M._rallyDirt.getDirectionalWearGrip = function(data, wheelID, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if type(data) ~= "table" or not cfg then return 1, 1, 1, 0.5, 0.5 end
    local profile = getWheelTyreProfile(wheelID).profile
    local physical = M._physicalThermal.getPhysicalProfile(profile)
    local nominal = math.max(finiteNumber(physical.treadDepthM, 0.011), 0.001)
    local reserve = getNonWearableTreadReserveM(nominal)
    local usable = math.max(nominal - reserve, 1e-6)
    local edges = M._rallyDirt.ensureBlockEdges(data)
    local wx, wy, xKey, yKey = M._rallyDirt.getDirectionState(wheelID)
    local weights = type(data.contact_zone_weights) == "table" and data.contact_zone_weights or {1 / 3, 1 / 3, 1 / 3}
    local heightHealth, xEdgeHealth, yEdgeHealth, weightSum = 0, 0, 0, 0
    for zone = 1, 3 do
        local weight = clamp(finiteNumber(weights[zone], 1 / 3), 0, 1)
        local depth = clamp(finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[zone], nominal), reserve, nominal)
        heightHealth = heightHealth + clamp((depth - reserve) / usable, 0, 1) * weight
        xEdgeHealth = xEdgeHealth + finiteNumber(edges[zone][xKey], 1) * weight
        yEdgeHealth = yEdgeHealth + finiteNumber(edges[zone][yKey], 1) * weight
        weightSum = weightSum + weight
    end
    heightHealth = heightHealth / math.max(weightSum, 1e-6)
    xEdgeHealth = xEdgeHealth / math.max(weightSum, 1e-6)
    yEdgeHealth = yEdgeHealth / math.max(weightSum, 1e-6)
    local mx = cfg.gripFloor + cfg.heightAuthority * (heightHealth ^ 0.75)
        + cfg.edgeAuthority * ((xEdgeHealth * math.sqrt(heightHealth)) ^ 1.25)
    local my = cfg.gripFloor + cfg.heightAuthority * (heightHealth ^ 0.75)
        + cfg.edgeAuthority * ((yEdgeHealth * math.sqrt(heightHealth)) ^ 1.25)
    local directional = 1 / math.sqrt(wx / math.max(mx * mx, 1e-6) + wy / math.max(my * my, 1e-6))
    return clamp(directional, cfg.gripFloor, 1.0), heightHealth, (xEdgeHealth + yEdgeHealth) * 0.5, wx, wy
end

M._rallyDirt.getMacroGrip = function(wheelID, surfaceClass)
    local data = tyreData[wheelID]
    if type(data) ~= "table" or not M._rallyDirt.surfaces[surfaceClass] then return 1 end
    local tempGrip, blockTemp = M._rallyDirt.getTemperatureGrip(data, surfaceClass)
    local wearGrip, heightHealth, activeEdgeHealth, wx, wy =
        M._rallyDirt.getDirectionalWearGrip(data, wheelID, surfaceClass)
    data.rally_dirt_block_temp_c = blockTemp
    data.rally_dirt_temp_multiplier = tempGrip
    data.rally_dirt_directional_wear_multiplier = wearGrip
    data.rally_block_height_health = heightHealth
    data.rally_block_active_edge_health = activeEdgeHealth
    data.rally_block_longitudinal_share = wx
    data.rally_block_lateral_share = wy
    return clamp(tempGrip * wearGrip, 0.02, 1.0)
end

M._rallyDirt.getFastGrip = function(flashState, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if not cfg then return 1 end
    local state = type(flashState) == "table" and flashState or {}
    local sliding = clamp(finiteNumber(state.brushSlidingLoadFraction, 0), 0, 1)
    local roadFast = clamp((1 - sliding) + sliding
        * clamp(finiteNumber(state.surfaceThermalModifier, 1), M._flashMemory.minGripMultiplier, 1)
        * clamp(finiteNumber(state.shortTermSurfaceModifier, 1), M._flashMemory.minGripMultiplier, 1),
        M._flashMemory.minGripMultiplier, 1)
    return clamp(1 - clamp(finiteNumber(cfg.fastHeatAuthority, 0), 0, 1) * (1 - roadFast), 0.05, 1)
end

M._rallyDirt.limitFastGrip = function(roadFastGrip, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if not cfg then return 1 end
    local raw = clamp(finiteNumber(roadFastGrip, 1), M._flashMemory.minGripMultiplier, 1)
    return clamp(1 - clamp(finiteNumber(cfg.fastHeatAuthority, 0), 0, 1) * (1 - raw), 0.05, 1)
end

M._rallyDirt.applyDirectionalEdgeWear = function(data, wheelID, zoneHeightWearDepthM,
                                                   nominalDepthM, surfaceClass)
    local cfg = M._rallyDirt.surfaces[surfaceClass]
    if not tyreWearEnabled or type(data) ~= "table" or not cfg then return end
    local edges = M._rallyDirt.ensureBlockEdges(data)
    local wx, wy, xKey, yKey = M._rallyDirt.getDirectionState(wheelID)
    local reserve = getNonWearableTreadReserveM(nominalDepthM)
    local usable = math.max(nominalDepthM - reserve, 1e-6)
    local heightScale = math.max(finiteNumber(cfg.heightWearScale, 1), 0.001)
    local edgeScale = math.max(finiteNumber(cfg.edgeWearScale, 1), 0)
    local totalX, totalY = 0, 0
    for zone = 1, 3 do
        local equivalentEdgeDepth = math.max(finiteNumber(zoneHeightWearDepthM[zone], 0), 0)
            * edgeScale / heightScale
        local normalizedLoss = equivalentEdgeDepth / usable
        local xLoss = normalizedLoss * wx
        local yLoss = normalizedLoss * wy
        edges[zone][xKey] = clamp(edges[zone][xKey] - xLoss, 0, 1)
        edges[zone][yKey] = clamp(edges[zone][yKey] - yLoss, 0, 1)
        totalX = totalX + xLoss
        totalY = totalY + yLoss
    end
    data.rally_block_edge_x_step = totalX / 3
    data.rally_block_edge_y_step = totalY / 3
end

M._rallyDirt.updateEdgeTelemetry = function(data)
    local edges = M._rallyDirt.ensureBlockEdges(data)
    if not edges then return end
    for _, key in ipairs({"xp", "xn", "yp", "yn"}) do
        data["rally_block_edge_" .. key] = (edges[1][key] + edges[2][key] + edges[3][key]) / 3
    end
end

M._physicalThermal.estimateInterfaceFrictionState = function(wheelID, groundModel, slipSpeed)
    local wd = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local gm = groundModel or {}
    local groundStatic = math.max(finiteNumber(gm.staticFrictionCoefficient, 1.0), 0.001)
    local groundSliding = math.max(finiteNumber(gm.slidingFrictionCoefficient, groundStatic), 0.001)
    local tyreStatic = math.max(finiteNumber(wd and wd.frictionCoef, 1.0), 0.001)
    local tyreSliding = math.max(finiteNumber(wd and wd.slidingFrictionCoef, tyreStatic), 0.001)
    local exponent = clamp(finiteNumber(wd and wd.stribeckExponent, M._flashMemory.nativeStribeckDefaultExponent), 0.10, 8.0)
    local velMult = clamp(finiteNumber(wd and wd.stribeckVelMult, M._flashMemory.nativeStribeckDefaultVelMult), 0.05, 10.0)
    local groundVs = math.max(finiteNumber(gm.stribeckVelocity, M._flashMemory.nativeStribeckFallbackVelocityMps), 0.05)
    local effectiveVs = math.max(groundVs * velMult, 0.05)
    local staticMu = groundStatic * tyreStatic
    local slidingMu = groundSliding * tyreSliding
    local ultimateRatio = clamp(slidingMu / math.max(staticMu, 0.001), 0.05, 2.0)
    local x = math.max(finiteNumber(slipSpeed, 0), 0) / effectiveVs
    local staticWeight = math.exp(-(x ^ exponent))
    local nodeRatio = ultimateRatio + (1 - ultimateRatio) * staticWeight
    local appliedGripScale = clamp(finiteNumber(tyreGripTable[wheelID], 1.0), 0.05, 2.0)
    return {
        staticMu = staticMu,
        slidingMu = slidingMu,
        ultimateRatio = ultimateRatio,
        nodeRatio = nodeRatio,
        effectiveMu = staticMu * nodeRatio * appliedGripScale,
        appliedGripScale = appliedGripScale,
        effectiveVelocity = effectiveVs,
        exponent = exponent,
    }
end

-- DIRECT NATIVE SLIP-POWER HEAT SOURCE.
--
-- Do not load `tech/wheelForces.lua` to scrape Fx/Fy for this path: its measurement
-- state is not a stable public getter API for an ordinary VLua mod, and loading the
-- stock tech extension can also enable its debug visualization.
--
-- BeamNG already exposes the quantity KTS actually needs for sliding heat directly on
-- every wheel rotator: `slipEnergy`. Historical BeamNG wheel code defines this as
-- smoothed instantaneous friction work rate (slipForce * slipVel, i.e. E/dt), and the
-- stock tyre-temperature path likewise used slipForce * slipVel * dt as collision heat.
-- Sources / provenance:
-- DIRECT BEAMNG RUNTIME SIGNAL: wheels.wheelRotators[wheelID].slipEnergy
-- BeamNG support pointer for force measurement context:
-- https://forum.beamng.tech/t/tire-forces-measurment/202
-- Historical BeamNG wheel callback semantics (p.slipForce * p.slipVel):
-- https://pastebin.com/xM8V1uMQ
-- BeamNG tyre-temperature discussion showing collisionEnergy = slipForce*slipVel*dt:
-- https://www.beamng.com/posts/1302649/
--
-- OWNERSHIP RULE: native slipEnergy owns TRUE SLIDING friction power
-- directly. It therefore MUST NOT be multiplied by KTS B/sliding fraction again.
-- B/Fiala remains responsible for (1) contact-patch adhering-vs-sliding diagnostics,
-- (2) the small additional hysteretic deformation/flex heat in the still-adhering
-- portion, and (3) compatibility fallback if slipEnergy is unavailable.
M._physicalThermal.nativeSlipPowerSource = {
    modelVersion = "beamng-wheelrotator-slipenergy-v1",
    enabled = true,
    moduleAvailable = false,
    moduleName = "wheels.wheelRotators[].slipEnergy",
    moduleKeys = "slipEnergy,lastSlip,lastSideSlip,downForceRaw",
    lastSource = "not-probed",
    lastError = "",
    validReadCount = 0,
    fallbackReadCount = 0,
}

M._physicalThermal.getNativeSlipPower = function(wheelID, wc, longitudinalSlipSpeed, lateralSlipSpeed)
    local state = M._physicalThermal.nativeSlipPowerSource
    if not state or state.enabled == false then return nil end

    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    if type(wr) ~= "table" then
        state.moduleAvailable = false
        state.lastSource = "legacy-fiala-mu-fallback:wheel-rotator-unavailable"
        state.fallbackReadCount = state.fallbackReadCount + 1
        return nil
    end

    local rawPower = finiteNumber(wr.slipEnergy, nil)
    if rawPower == nil then
        state.moduleAvailable = false
        state.lastSource = "legacy-fiala-mu-fallback:slipEnergy-unavailable"
        state.lastError = "wheels.wheelRotators[wheelID].slipEnergy is nil/non-finite"
        state.fallbackReadCount = state.fallbackReadCount + 1
        return nil
    end

    state.moduleAvailable = true
    local powerW = math.abs(rawPower)
    local vx = math.abs(finiteNumber(longitudinalSlipSpeed, finiteNumber(wc and wc.longitudinalSlipSpeed, 0)))
    local vy = math.abs(finiteNumber(lateralSlipSpeed, finiteNumber(wc and wc.lateralSlipSpeed, 0)))
    local v2 = vx * vx + vy * vy
    local combinedSlip = math.sqrt(v2)
    local loadN = math.abs(finiteNumber(wr.downForceRaw, finiteNumber(wc and wc.downForceRaw, 0)))

    local sanePowerCapW = math.max(loadN * math.max(combinedSlip, 1) * 20, 5000000)
    if powerW > sanePowerCapW then
        state.lastSource = "legacy-fiala-mu-fallback:slipEnergy-sanity"
        state.lastError = "slipEnergy=" .. tostring(powerW) .. "W cap=" .. tostring(sanePowerCapW) .. "W"
        state.fallbackReadCount = state.fallbackReadCount + 1
        return nil
    end

    local longitudinalPowerW, lateralPowerW = 0, 0
    local equivalentFxN, equivalentFyN, equivalentTangentialForceN = 0, 0, 0
    if v2 > 1e-8 then
        longitudinalPowerW = powerW * (vx * vx / v2)
        lateralPowerW = powerW * (vy * vy / v2)
        equivalentFxN = powerW * vx / v2
        equivalentFyN = powerW * vy / v2
        equivalentTangentialForceN = powerW / math.sqrt(v2)
    end

    state.lastSource = "wheels.wheelRotators[wheelID].slipEnergy"
    state.lastError = ""
    state.validReadCount = state.validReadCount + 1
    return {
        powerW = powerW,
        longitudinalPowerW = longitudinalPowerW,
        lateralPowerW = lateralPowerW,
        ktsCombinedSlipMps = combinedSlip,
        beamngLastSlipMps = math.abs(finiteNumber(wr.lastSlip, finiteNumber(wc and wc.lastSlip, 0))),
        equivalentFxN = equivalentFxN,
        equivalentFyN = equivalentFyN,
        equivalentTangentialForceN = equivalentTangentialForceN,
        source = state.lastSource,
        semantics = "direct-native-sliding-friction-power; equivalent force is diagnostic only",
    }
end

local function NormalizeThreeWeights(raw)
    local a = math.max(finiteNumber(raw and raw[1], 0), 0)
    local b = math.max(finiteNumber(raw and raw[2], 0), 0)
    local c = math.max(finiteNumber(raw and raw[3], 0), 0)
    local sum = a + b + c
    if sum <= 1e-9 then return {1 / 3, 1 / 3, 1 / 3} end
    return {a / sum, b / sum, c / sum}
end

local function CalcBiasWeights(loadBias)
    local safeBias = clamp(finiteNumber(loadBias, 0), -1, 1)
    local absBias = math.abs(safeBias)
    local weightCenter
    if absBias < 1e-9 then
        weightCenter = 1.0
    else
        weightCenter = -1 / (1 + 5 * (safeBias ^ -2)) + 1
    end
    local weightLeft = -0.75 * safeBias + 1
    local weightRight = 0.75 * safeBias + 1
    local weightSum = weightLeft + weightCenter + weightRight
    return {weightLeft / weightSum, weightCenter / weightSum, weightRight / weightSum}
end

--
local function CalcResearchCrossTreadWeights(profileID, loadBias, loadRatio, livePressurePsi, referencePressurePsi,
                                              stiffnessFactor, lateralSigma, baseCriticalSigmaY)
    local cfg = M._crossTreadResearch or {}
    if cfg.enabled == false then
        local fallback = CalcBiasWeights(loadBias)
        return fallback, fallback, {enabled = false}
    end

    local profileKey = string.lower(tostring(profileID or "standard"))
    local safeLoadRatio = clamp(finiteNumber(loadRatio, 1), 0.05, 8.0)
    local livePsi = math.max(finiteNumber(livePressurePsi, 30), MIN_NUMERIC_PRESSURE_PSI)
    local refPsi = math.max(finiteNumber(referencePressurePsi, livePsi), MIN_NUMERIC_PRESSURE_PSI)
    local stiffness = clamp(finiteNumber(stiffnessFactor, 1), 0.20, 5.0)
    local compliance = 1 / stiffness

    --
    --
    --
    --
    local crownSupportTable = cfg.crownSupportRatioByProfile or {}
    local crownSupport = math.max(finiteNumber(crownSupportTable[profileKey], 0), 0)
    local loadAuthority = 1 / (1 + crownSupport * math.max(finiteNumber(cfg.crownLoadCoupling, 0.65), 0))
    local pressureAuthority = 1 / (1 + crownSupport * math.max(finiteNumber(cfg.crownPressureCoupling, 0.45), 0))
    local flexAuthority = 1 / (1 + crownSupport * math.max(finiteNumber(cfg.crownFlexCoupling, 0.75), 0))

    local effectiveCompliance = (1 + crownSupport) / math.max(stiffness + crownSupport, 0.01)
    local pressureRatio = refPsi / livePsi

    local effectiveLoadRatio = math.exp(math.log(math.max(safeLoadRatio, 1e-6)) * loadAuthority)
    local effectivePressureRatio = math.exp(math.log(math.max(pressureRatio, 1e-6)) * pressureAuthority)

    local deflectionIndex =
        (effectiveLoadRatio ^ clamp(finiteNumber(cfg.loadRatioExponent, 0.65), 0, 1.5))
        * (effectivePressureRatio ^ clamp(finiteNumber(cfg.pressureRatioExponent, 0.95), 0, 2.0))
        * (effectiveCompliance ^ clamp(finiteNumber(cfg.complianceExponent, 0.65), 0, 2.0))
    deflectionIndex = clamp(deflectionIndex, 0.10, 10.0)

    local minSCR = clamp(finiteNumber(cfg.minShoulderCenterRatio, 0.70), 0.20, 1.0)
    local maxSCR = clamp(finiteNumber(cfg.maxShoulderCenterRatio, 2.00), 1.0, 5.0)
    local shoulderCenterLog = clamp(
        finiteNumber(cfg.pressureShapeGain, 0.75) * math.log(deflectionIndex),
        math.log(minSCR), math.log(maxSCR))

    local sideLog = clamp(
        clamp(finiteNumber(loadBias, 0), -1, 1) * finiteNumber(cfg.lateralLoadShiftGain, 0.50),
        -math.abs(finiteNumber(cfg.maxLateralLoadShiftLog, 0.60)),
         math.abs(finiteNumber(cfg.maxLateralLoadShiftLog, 0.60)))

    local phi = {1 / 3, -2 / 3, 1 / 3}
    local psi = {-1, 0, 1}
    local contactRaw = {}
    for i = 1, 3 do
        contactRaw[i] = math.exp(shoulderCenterLog * phi[i] + sideLog * psi[i])
    end
    local contactWeights = NormalizeThreeWeights(contactRaw)

    local baseSigma = math.max(math.abs(finiteNumber(baseCriticalSigmaY, 0.225)), 0.01)
    local lateralDemand = clamp(math.abs(finiteNumber(lateralSigma, 0)) / baseSigma, 0, 1.0)
    local complianceForFlex = effectiveCompliance ^ clamp(finiteNumber(cfg.flexComplianceExponent, 1.0), 0, 2.0)
    local flexStrainProxy = clamp(lateralDemand * complianceForFlex, 0, 1.5)
    local maxFlexRatio = clamp(finiteNumber(cfg.maxFlexShoulderCenterRatio, 2.50), 1.0, 6.0)
    local flexEdgeLog = clamp(
        finiteNumber(cfg.flexEdgeGain, 0.65) * flexStrainProxy * flexStrainProxy * flexAuthority,
        0, math.log(maxFlexRatio))
    local flexRaw = {}
    for i = 1, 3 do
        flexRaw[i] = contactWeights[i] * math.exp(flexEdgeLog * phi[i])
    end
    local flexWeights = NormalizeThreeWeights(flexRaw)

    local hysteresisComplianceGain = clamp(
        effectiveCompliance ^ clamp(finiteNumber(cfg.lateralHysteresisComplianceExponent, 0.65), 0, 2.0),
        finiteNumber(cfg.minLateralHysteresisGain, 0.65),
        finiteNumber(cfg.maxLateralHysteresisGain, 1.65))

    return contactWeights, flexWeights, {
        enabled = true,
        profileID = profileKey,
        deflectionIndex = deflectionIndex,
        shoulderCenterRatio = math.exp(shoulderCenterLog),
        lateralLoadShiftLog = sideLog,
        compliance = compliance,
        effectiveCompliance = effectiveCompliance,
        rawLoadRatio = safeLoadRatio,
        effectiveLoadRatio = effectiveLoadRatio,
        rawPressureRatio = pressureRatio,
        effectivePressureRatio = effectivePressureRatio,
        crownSupportRatio = crownSupport,
        crownLoadAuthority = loadAuthority,
        crownPressureAuthority = pressureAuthority,
        crownFlexAuthority = flexAuthority,
        lateralDemand = lateralDemand,
        flexStrainProxy = flexStrainProxy,
        flexShoulderCenterRatio = math.exp(flexEdgeLog),
        hysteresisComplianceGain = hysteresisComplianceGain,
    }
end

local function CalcWearProfileCamberCorrectionDeg(wheelID, tyreWidthM)
    local data = tyreData and tyreData[wheelID]
    local depths = data and data.tread_remaining_depth_m
    if type(depths) ~= "table" then return 0, 0 end

    local outerDepth = finiteNumber(depths[1], 0)
    local innerDepth = finiteNumber(depths[3], outerDepth)
    local depthDeltaM = outerDepth - innerDepth

    local effectiveSpanM = math.max(math.abs(finiteNumber(tyreWidthM, 0.20)) * 0.86, 0.045)
    local wedgeDeg = math.deg(math.atan(depthDeltaM / effectiveSpanM))
    return clamp(wedgeDeg, -3.0, 3.0), depthDeltaM * 1000
end

TempRingsToAvgTemp = function(temps, loadBias, overrideWeights)
    local weights = type(overrideWeights) == "table" and overrideWeights or CalcBiasWeights(loadBias)
    local weighted, weightSum = 0, 0
    if type(temps) == "table" then
        for i = 1, 3 do
            local t = temps[i]
            local w = finiteNumber(weights and weights[i], 0)
            if type(t) == "number" and t == t and t ~= math.huge and t ~= -math.huge and w > 0 then
                weighted = weighted + t * w
                weightSum = weightSum + w
            end
        end
        if weightSum > 1e-12 then return weighted / weightSum end
        for _, t in pairs(temps) do
            if type(t) == "number" and t == t and t ~= math.huge and t ~= -math.huge then return t end
        end
    end
    return finiteNumber(ENV_TEMP, 20)
end

M._tread1D.evaluateDirectSurfaceGrip = function(data, profile, loadBias, overrideWeights, useLocalContact, thermalCache)
    if type(data)~="table" or type(profile)~="table" then return 1.0,1.0,finiteNumber(ENV_TEMP,20),nil end
    local physical=M._physicalThermal.getPhysicalProfile(profile)
    local decay=math.max(finiteNumber(physical and physical.gripDepthDecayM,M._tread1D.gripDepthDecayM),0.0001)
    local contactWeights=type(overrideWeights)=="table" and overrideWeights or CalcBiasWeights(loadBias)
    local localCellsByZone=useLocalContact and data.circumferential_contact_grip_cells_zone_c or nil
    local zoneGrip,zoneTemp={1,1,1},{ENV_TEMP,ENV_TEMP,ENV_TEMP}; local totalGrip,totalTemp,contactSum=0,0,0
    for z=1,3 do
        local field=(thermalCache and thermalCache.treadField and thermalCache.treadField[z]) or (data.tread_field and data.tread_field[z])
        local localCells=type(localCellsByZone)=="table" and localCellsByZone[z] or nil
        local zg=thermalCache and thermalCache.zoneGeometry and thermalCache.zoneGeometry[z]
        if type(zg)~="table" then zg=M._tread1D.buildZoneCellGeometry(data,physical,z,1,finiteNumber(physical.rubberDensity,M._physicalThermal.rubberDensity),finiteNumber(physical.rubberCp,M._physicalThermal.rubberCp)) end
        local gripNumerator,tempNumerator,depthWeightSum=0,0,0
        for j=1,zg.activeCount do
            local T=finiteNumber(type(localCells)=="table" and localCells[j],finiteNumber(type(field)=="table" and field[j],finiteNumber(data.temp and data.temp[z],ENV_TEMP)))
            local w=M._tread1D.getGripDepthWeightFromGeometry(zg,j,decay); local curveTemp=T-finiteNumber(data.working_temp,profile.workingTemp)+profile.workingTemp
            local cellGrip=interpolateProfileGrip(profile,curveTemp); if curveTemp>profile.overheatStart then cellGrip=clamp(1-(1-cellGrip)*HOT_GRIP_LOSS_FACTOR,0.05,1.0) end
            gripNumerator=gripNumerator+cellGrip*w; tempNumerator=tempNumerator+T*w; depthWeightSum=depthWeightSum+w
        end
        zoneGrip[z]=gripNumerator/math.max(depthWeightSum,1e-9); zoneTemp[z]=tempNumerator/math.max(depthWeightSum,1e-9)
        local cw=clamp(finiteNumber(contactWeights[z],1/3),0,1); totalGrip=totalGrip+zoneGrip[z]*cw; totalTemp=totalTemp+zoneTemp[z]*cw; contactSum=contactSum+cw
    end
    local realistic=clamp(totalGrip/math.max(contactSum,1e-9),0.05,1.0); local repT=totalTemp/math.max(contactSum,1e-9); local applied=M._arcadeHandling.applyThermalPenalty(realistic)
    return clamp(applied,0.05,1.0),realistic,repT,zoneGrip
end

-- LuaJIT local-register guard: keep the late wear/remesh machinery out of
-- CalcTyreWear(). This module is close to LuaJIT's ~200-local compile limit, so
-- remeshing remains isolated here. Per-zone wear DEPTH comes from the measured local
-- wear law while this separation protects CalcTyreWear from local-register overflow.
local function ApplyTreadWearAndRemesh(wheelID, data, physical, profile, nominalTreadDepth, wearDepthByZoneM,
                                       flashFastDepthByZoneM, contactWeights, loadBias)
    local requested=type(wearDepthByZoneM)=="table" and wearDepthByZoneM or nil
    local fastRequested=type(flashFastDepthByZoneM)=="table" and flashFastDepthByZoneM or nil
    data.pending_tread_wear_depth_m=type(data.pending_tread_wear_depth_m)=="table" and data.pending_tread_wear_depth_m or {0,0,0}
    data.pending_flash_fast_wear_depth_m=type(data.pending_flash_fast_wear_depth_m)=="table" and data.pending_flash_fast_wear_depth_m or {0,0,0}
    data.pending_localized_tread_wear_depth_m=type(data.pending_localized_tread_wear_depth_m)=="table" and data.pending_localized_tread_wear_depth_m or {0,0,0}
    data.pending_flash_localized_tread_wear_depth_m=type(data.pending_flash_localized_tread_wear_depth_m)=="table" and data.pending_flash_localized_tread_wear_depth_m or {0,0,0}
    local circState=data.circumferential_state
    local localFraction=tyreWearEnabled and type(circState)=="table" and clamp(finiteNumber(circState.localFraction,0),0,1) or 0
    local localizedStepTotal=0
    local fastLocalizedStepTotal=0
    for z=1,3 do
        local step=math.max(finiteNumber(requested and requested[z],0),0)
        local fastStep=math.min(math.max(finiteNumber(fastRequested and fastRequested[z],0),0),step)
        local normalStep=math.max(step-fastStep,0)
        data.pending_tread_wear_depth_m[z]=math.max(finiteNumber(data.pending_tread_wear_depth_m[z],0),0)+step
        data.pending_flash_fast_wear_depth_m[z]=math.max(finiteNumber(data.pending_flash_fast_wear_depth_m[z],0),0)+fastStep
        local localizedStep=normalStep*localFraction
        local fastLocalizedStep=fastStep*localFraction
        data.pending_localized_tread_wear_depth_m[z]=math.max(finiteNumber(data.pending_localized_tread_wear_depth_m[z],0),0)+localizedStep
        data.pending_flash_localized_tread_wear_depth_m[z]=math.max(finiteNumber(data.pending_flash_localized_tread_wear_depth_m[z],0),0)+fastLocalizedStep
        localizedStepTotal=localizedStepTotal+localizedStep
        fastLocalizedStepTotal=fastLocalizedStepTotal+fastLocalizedStep
    end
    if type(circState)=="table" then
        local phase=M._circumferential.wrap01(finiteNumber(circState.depositPhase,circState.phase))
        local angle=phase*2*math.pi
        local width=clamp(finiteNumber(circState.depositHalfWidthTurns,M._circumferential.minHalfWidthTurns),M._circumferential.minHalfWidthTurns,M._circumferential.maxHalfWidthTurns)
        if localizedStepTotal>0 then
            data.pending_wear_phase_cos=finiteNumber(data.pending_wear_phase_cos,0)+math.cos(angle)*localizedStepTotal
            data.pending_wear_phase_sin=finiteNumber(data.pending_wear_phase_sin,0)+math.sin(angle)*localizedStepTotal
            data.pending_wear_phase_weight=finiteNumber(data.pending_wear_phase_weight,0)+localizedStepTotal
            data.pending_wear_width_weight=finiteNumber(data.pending_wear_width_weight,0)+width*localizedStepTotal
        end
        if fastLocalizedStepTotal>0 then
            data.pending_flash_wear_phase_cos=finiteNumber(data.pending_flash_wear_phase_cos,0)+math.cos(angle)*fastLocalizedStepTotal
            data.pending_flash_wear_phase_sin=finiteNumber(data.pending_flash_wear_phase_sin,0)+math.sin(angle)*fastLocalizedStepTotal
            data.pending_flash_wear_phase_weight=finiteNumber(data.pending_flash_wear_phase_weight,0)+fastLocalizedStepTotal
            data.pending_flash_wear_width_weight=finiteNumber(data.pending_flash_wear_width_weight,0)+width*fastLocalizedStepTotal
        end
    end

    local tick=math.max(math.floor(finiteNumber(data.thermal_master_tick,0)),0)
    if data.last_wear_commit_thermal_tick~=nil and tick==data.last_wear_commit_thermal_tick then return false end

    local reserve=getNonWearableTreadReserveM(nominalTreadDepth)
    local usableDepthM=math.max(nominalTreadDepth-reserve,1e-6)
    local wearWriteDeadbandPercent=0.10
    local wearWriteDeadbandDepthM=usableDepthM*(wearWriteDeadbandPercent/100)
    local fastRemeshThresholdM=math.max(finiteNumber(M._wearResearch.flashFastRemeshThresholdM,0.000010),1e-7)
    data.wear_write_deadband_percent=wearWriteDeadbandPercent
    data.wear_write_deadband_depth_m=wearWriteDeadbandDepthM
    data.wear_flash_fast_remesh_threshold_m=fastRemeshThresholdM
    data.wear_pending_write_percent=type(data.wear_pending_write_percent)=="table" and data.wear_pending_write_percent or {0,0,0}
    local pendingSum=0
    local fastPendingMax=0
    local reachesReserve=false
    for z=1,3 do
        local pending=math.max(finiteNumber(data.pending_tread_wear_depth_m[z],0),0)
        local fastPending=math.min(math.max(finiteNumber(data.pending_flash_fast_wear_depth_m[z],0),0),pending)
        local oldDepth=clamp(finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[z],nominalTreadDepth),reserve,nominalTreadDepth)
        data.wear_pending_write_percent[z]=pending/usableDepthM*100
        pendingSum=pendingSum+pending
        fastPendingMax=math.max(fastPendingMax,fastPending)
        reachesReserve=reachesReserve or (tyreWearEnabled and pending>0 and (oldDepth-pending)<=reserve+1e-12)
    end
    local pendingMeanDepthM=pendingSum/3
    data.wear_pending_write_mean_percent=pendingMeanDepthM/usableDepthM*100
    data.wear_pending_write_max_percent=math.max(data.wear_pending_write_percent[1],data.wear_pending_write_percent[2],data.wear_pending_write_percent[3])
    data.wear_flash_fast_pending_max_m=fastPendingMax

    local normalCadence=(tick%12)==0
    local normalShouldCommit=normalCadence and ((not tyreWearEnabled and pendingSum>0) or pendingMeanDepthM>=wearWriteDeadbandDepthM or reachesReserve)
    local fastShouldCommit=fastPendingMax>=fastRemeshThresholdM
    if not normalShouldCommit and not fastShouldCommit then
        data.wear_write_suppressed=pendingSum>0
        return false
    end
    data.last_wear_commit_thermal_tick=tick
    data._wearCommitScratch=type(data._wearCommitScratch)=="table" and data._wearCommitScratch or {0,0,0}
    requested=data._wearCommitScratch
    local fastCommit=(not normalShouldCommit) and fastShouldCommit
    if fastCommit then
        for z=1,3 do
            local fastPending=math.min(math.max(finiteNumber(data.pending_flash_fast_wear_depth_m[z],0),0),math.max(finiteNumber(data.pending_tread_wear_depth_m[z],0),0))
            requested[z]=fastPending
            data.pending_flash_fast_wear_depth_m[z]=0
            data.pending_tread_wear_depth_m[z]=math.max(finiteNumber(data.pending_tread_wear_depth_m[z],0)-fastPending,0)
        end
        data.wear_commit_mode="flash-fast"
        data.wear_flash_fast_commit_count=finiteNumber(data.wear_flash_fast_commit_count,0)+1
    else
        for z=1,3 do
            requested[z]=math.max(finiteNumber(data.pending_tread_wear_depth_m[z],0),0)
            data.pending_tread_wear_depth_m[z]=0
            data.pending_flash_fast_wear_depth_m[z]=0
        end
        data.wear_commit_mode="normal-deadband"
    end
    data.wear_write_suppressed=false
    data.wear_commit_count=finiteNumber(data.wear_commit_count,0)+1

    if tyreWearEnabled and M._circumferential.enabled then
        if fastCommit then
            data._wearLocalizedCommitScratch=type(data._wearLocalizedCommitScratch)=="table" and data._wearLocalizedCommitScratch or {0,0,0}
            local localized=data._wearLocalizedCommitScratch
            local localizedTotal=0
            for z=1,3 do localized[z]=math.max(finiteNumber(data.pending_flash_localized_tread_wear_depth_m[z],0),0); data.pending_flash_localized_tread_wear_depth_m[z]=0; localizedTotal=localizedTotal+localized[z] end
            local phaseWeight=math.max(finiteNumber(data.pending_flash_wear_phase_weight,0),0); local phaseCos=finiteNumber(data.pending_flash_wear_phase_cos,0); local phaseSin=finiteNumber(data.pending_flash_wear_phase_sin,0)
            local coherence=phaseWeight>1e-12 and math.sqrt(phaseCos*phaseCos+phaseSin*phaseSin)/phaseWeight or 0
            data.wear_flash_localization_batch_coherence=coherence
            if localizedTotal>0 and phaseWeight>1e-12 and coherence>=0.25 then
                local phaseAngle
                if type(math.atan2)=="function" then phaseAngle=math.atan2(phaseSin,phaseCos) elseif phaseCos>0 then phaseAngle=math.atan(phaseSin/phaseCos) elseif phaseCos<0 then phaseAngle=math.atan(phaseSin/phaseCos)+(phaseSin>=0 and math.pi or -math.pi) elseif phaseSin>0 then phaseAngle=0.5*math.pi elseif phaseSin<0 then phaseAngle=-0.5*math.pi else phaseAngle=0 end
                local phase=M._circumferential.wrap01(phaseAngle/(2*math.pi)); local halfWidth=clamp(finiteNumber(data.pending_flash_wear_width_weight,0)/phaseWeight,M._circumferential.minHalfWidthTurns,M._circumferential.maxHalfWidthTurns)
                M._circumferential.mergeWearFeature(M._circumferential.ensureState(data),phase,halfWidth,localized)
            end
            data.pending_flash_wear_phase_cos=0; data.pending_flash_wear_phase_sin=0; data.pending_flash_wear_phase_weight=0; data.pending_flash_wear_width_weight=0
        else
            data._wearLocalizedCommitScratch=type(data._wearLocalizedCommitScratch)=="table" and data._wearLocalizedCommitScratch or {0,0,0}
            local localized=data._wearLocalizedCommitScratch
            local fastTotal=0
            for z=1,3 do localized[z]=math.max(finiteNumber(data.pending_flash_localized_tread_wear_depth_m[z],0),0); data.pending_flash_localized_tread_wear_depth_m[z]=0; fastTotal=fastTotal+localized[z] end
            local fpw=math.max(finiteNumber(data.pending_flash_wear_phase_weight,0),0); local fpc=finiteNumber(data.pending_flash_wear_phase_cos,0); local fps=finiteNumber(data.pending_flash_wear_phase_sin,0); local fcoh=fpw>1e-12 and math.sqrt(fpc*fpc+fps*fps)/fpw or 0
            if fastTotal>0 and fpw>1e-12 and fcoh>=0.25 then
                local a; if type(math.atan2)=="function" then a=math.atan2(fps,fpc) elseif fpc>0 then a=math.atan(fps/fpc) elseif fpc<0 then a=math.atan(fps/fpc)+(fps>=0 and math.pi or -math.pi) elseif fps>0 then a=0.5*math.pi elseif fps<0 then a=-0.5*math.pi else a=0 end
                M._circumferential.mergeWearFeature(M._circumferential.ensureState(data),M._circumferential.wrap01(a/(2*math.pi)),clamp(finiteNumber(data.pending_flash_wear_width_weight,0)/fpw,M._circumferential.minHalfWidthTurns,M._circumferential.maxHalfWidthTurns),localized)
            end
            data.pending_flash_wear_phase_cos=0; data.pending_flash_wear_phase_sin=0; data.pending_flash_wear_phase_weight=0; data.pending_flash_wear_width_weight=0

            local normalTotal=0
            for z=1,3 do localized[z]=math.max(finiteNumber(data.pending_localized_tread_wear_depth_m[z],0),0); data.pending_localized_tread_wear_depth_m[z]=0; normalTotal=normalTotal+localized[z] end
            local phaseWeight=math.max(finiteNumber(data.pending_wear_phase_weight,0),0); local phaseCos=finiteNumber(data.pending_wear_phase_cos,0); local phaseSin=finiteNumber(data.pending_wear_phase_sin,0); local coherence=phaseWeight>1e-12 and math.sqrt(phaseCos*phaseCos+phaseSin*phaseSin)/phaseWeight or 0
            data.wear_localization_batch_coherence=coherence
            if normalTotal>0 and phaseWeight>1e-12 and coherence>=0.25 then
                local phaseAngle; if type(math.atan2)=="function" then phaseAngle=math.atan2(phaseSin,phaseCos) elseif phaseCos>0 then phaseAngle=math.atan(phaseSin/phaseCos) elseif phaseCos<0 then phaseAngle=math.atan(phaseSin/phaseCos)+(phaseSin>=0 and math.pi or -math.pi) elseif phaseSin>0 then phaseAngle=0.5*math.pi elseif phaseSin<0 then phaseAngle=-0.5*math.pi else phaseAngle=0 end
                M._circumferential.mergeWearFeature(M._circumferential.ensureState(data),M._circumferential.wrap01(phaseAngle/(2*math.pi)),clamp(finiteNumber(data.pending_wear_width_weight,0)/phaseWeight,M._circumferential.minHalfWidthTurns,M._circumferential.maxHalfWidthTurns),localized)
            end
            data.pending_wear_phase_cos=0; data.pending_wear_phase_sin=0; data.pending_wear_phase_weight=0; data.pending_wear_width_weight=0
        end
    elseif not tyreWearEnabled then
        if fastCommit then
            for z=1,3 do data.pending_flash_localized_tread_wear_depth_m[z]=0 end
            data.pending_flash_wear_phase_cos=0; data.pending_flash_wear_phase_sin=0; data.pending_flash_wear_phase_weight=0; data.pending_flash_wear_width_weight=0
        else
            for z=1,3 do data.pending_localized_tread_wear_depth_m[z]=0; data.pending_flash_localized_tread_wear_depth_m[z]=0 end
            data.pending_wear_phase_cos=0; data.pending_wear_phase_sin=0; data.pending_wear_phase_weight=0; data.pending_wear_width_weight=0
            data.pending_flash_wear_phase_cos=0; data.pending_flash_wear_phase_sin=0; data.pending_flash_wear_phase_weight=0; data.pending_flash_wear_width_weight=0
        end
    end

    local avg=(requested[1]+requested[2]+requested[3])/3
    local didThermalRemesh=avg>0 and type(data.tread_field)=="table"
    if didThermalRemesh then
        data.virtual_regenerated_depth_m=finiteNumber(data.virtual_regenerated_depth_m,0); data.wear_exported_thermal_energy_j=finiteNumber(data.wear_exported_thermal_energy_j,0); data.adaptive_remap_energy_error_j=finiteNumber(data.adaptive_remap_energy_error_j,0); data.tread_cell_retirements=type(data.tread_cell_retirements)=="table" and data.tread_cell_retirements or {0,0,0}
        local remainingSum=0; local areaPerZone=math.max(finiteNumber(data.tyre_tread_area_m2,0.15)/3,1e-6); local material=M._physicalThermal.getEffectiveTreadMaterial(profile); local rho=finiteNumber(material and material.density,finiteNumber(physical.rubberDensity,M._physicalThermal.rubberDensity)); local cp=finiteNumber(material and material.cp,finiteNumber(physical.rubberCp,M._physicalThermal.rubberCp))
        for z=1,3 do
            local oldDepth=clamp(finiteNumber(data.tread_remaining_depth_m[z],nominalTreadDepth),reserve,nominalTreadDepth)
            local removed=math.min(math.max(requested[z],0),math.max(oldDepth-reserve,0))
            local newDepth=oldDepth
            if removed>0 then
                local fillTemp
                if tyreWearEnabled then newDepth=math.max(oldDepth-removed,reserve); fillTemp=finiteNumber(data.temp[4],data.working_temp) else fillTemp=M._tread1D.getWearOffRegenFillTemp(data,profile); data.wear_regen_fill_temp_c=fillTemp; data.virtual_regenerated_depth_m=data.virtual_regenerated_depth_m+removed end
                data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}
                if tyreWearEnabled then
                    local oldGeomPending=M._tread1D.buildZoneCellGeometry(data,physical,z,areaPerZone,rho,cp); local ts=data.multi_rate_thermal_state
                    if type(ts)=="table" and type(ts.pendingCellJ)=="table" and type(ts.pendingCellJ[z])=="table" then for j=1,oldGeomPending.activeCount do local e=finiteNumber(ts.pendingCellJ[z][j],0); if math.abs(e)>0 then data.tread_field[z][j]=M._tread1D.applyEnergyJ(data.tread_field[z][j],oldGeomPending.capacityJPerK[j],e,ENV_TEMP-10,M._tread1D.maxCellTemp); ts.pendingCellJ[z][j]=0 end end end
                    local cs=data.circumferential_state; if type(cs)=="table" and type(cs.pendingBulkCellEnergyJ)=="table" and type(cs.pendingBulkCellEnergyJ[z])=="table" then for j=1,oldGeomPending.activeCount do local e=finiteNumber(cs.pendingBulkCellEnergyJ[z][j],0); if math.abs(e)>0 then data.tread_field[z][j]=M._tread1D.applyEnergyJ(data.tread_field[z][j],oldGeomPending.capacityJPerK[j],e,ENV_TEMP-10,M._tread1D.maxCellTemp); cs.pendingBulkCellEnergyJ[z][j]=0 end end end
                    local oldCount=#data.tread_field[z]; local remapped,oldGeom,newGeom,exportedJ,errorJ=M._tread1D.remapZoneConservative(data,physical,z,oldDepth,newDepth,removed,fillTemp,areaPerZone,rho,cp); data.tread_field[z]=remapped; data.wear_exported_thermal_energy_j=data.wear_exported_thermal_energy_j+finiteNumber(exportedJ,0); data.adaptive_remap_energy_error_j=data.adaptive_remap_energy_error_j+finiteNumber(errorJ,0)
                    M._circumferential.remapAdaptiveZoneLayers(data,z,oldGeom,newGeom,removed)
                    if newGeom.activeCount<oldCount then data.tread_cell_retirements[z]=finiteNumber(data.tread_cell_retirements[z],0)+(oldCount-newGeom.activeCount) end
                else
                    local oldGeomVirtual=M._tread1D.buildZoneCellGeometry(data,physical,z,areaPerZone,rho,cp)
                    data.tread_field[z]=M._tread1D.remapZone(data.tread_field[z],oldDepth,newDepth,removed,fillTemp)
                    local newGeomVirtual=M._tread1D.buildZoneCellGeometry(data,physical,z,areaPerZone,rho,cp)
                    local virtualHotspotExportJ=M._circumferential.remapAdaptiveZoneLayers(data,z,oldGeomVirtual,newGeomVirtual,removed)
                    data.virtual_wear_exported_hotspot_energy_j=finiteNumber(data.virtual_wear_exported_hotspot_energy_j,0)+finiteNumber(virtualHotspotExportJ,0)
                end
                data.surface_boundary_temp[z]=finiteNumber(data.tread_field[z][1],fillTemp)
                data.surface_boundary_wear_reset_count=finiteNumber(data.surface_boundary_wear_reset_count,0)+1
                data.tread_remaining_depth_m[z]=newDepth
            end
            remainingSum=remainingSum+newDepth
        end
        M._tread1D.ensureAdaptiveField(data,physical); data.b100_slow_cache_dirty=true; data.thermal_cache_force_publish=true
        if tyreWearEnabled then
            if M._thermalGripCacheByWheel then M._thermalGripCacheByWheel[wheelID]=nil end
            if M._pressureWheelBrush and M._pressureWheelBrush.slowCacheByWheel then M._pressureWheelBrush.slowCacheByWheel[wheelID]=nil end
        end
        if tyreWearEnabled then data.condition=physicalTreadDepthToCondition(remainingSum/3,nominalTreadDepth); if data.condition<0.0001 then data.condition=0 end end
        M._tread1D.deriveTemps(data,physical); data.surface_avg_temp=TempRingsToAvgTemp(data.surface_temp,loadBias,contactWeights); data.grip_depth_avg_temp=TempRingsToAvgTemp(data.temp,loadBias,contactWeights); data.bulk_tread_avg_temp=TempRingsToAvgTemp(data.tread_bulk_temp or data.temp,loadBias,contactWeights)
    elseif tyreWearEnabled and avg>0 then
        data.condition=math.max(data.condition-avg/math.max(nominalTreadDepth-reserve,1e-6)*100,0)
    end
    return didThermalRemesh
end

local function BuildTyreThermalGeometry(data, physical, material, tyreWidth, wheelRadius, loadRaw,
                                        pressurePa, groundSpeed, airspeed, combinedSlipSpeed,
                                        longitudinalSlipSpeed, lateralSlipSpeed, groundModel, loadBias)
    local g = {}
    g.safeWidth = clamp(finiteNumber(tyreWidth, 0.20), 0.05, 0.60)
    g.safeRadius = clamp(finiteNumber(wheelRadius, 0.33), 0.10, 1.50)
    g.treadArea = math.max(2 * math.pi * g.safeRadius * g.safeWidth, 0.05)
    g.exposedArea = g.treadArea
    g.treadCoolingWidth = g.safeWidth
    g.treadCoolingWidthFactor = 1.0
    g.treadCells = math.max(math.floor(finiteNumber(M._tread1D.cells, 12)), 1)
    M._tread1D.ensureField(data, physical)
    if type(data.tread_bulk_temp) ~= "table"
        or type(data.tread_bulk_temp[1]) ~= "number"
        or type(data.tread_bulk_temp[2]) ~= "number"
        or type(data.tread_bulk_temp[3]) ~= "number" then
        M._tread1D.deriveTemps(data, physical)
    end
    data._thermalActiveCellsScratch=type(data._thermalActiveCellsScratch)=="table" and data._thermalActiveCellsScratch or {}
    data._thermalTopologyScratch=type(data._thermalTopologyScratch)=="table" and data._thermalTopologyScratch or {{},{},{},{}}
    g.activeTreadCellsByZone=data._thermalActiveCellsScratch
    g._topologyScratch=data._thermalTopologyScratch
    g.maxActiveTreadCells = 1
    for z=1,3 do
        local topo=M._tread1D.getCellTopologyForDepth(data.tread_remaining_depth_m[z],physical,true,g._topologyScratch[z])
        g.activeTreadCellsByZone[z]=topo.activeCount; g.maxActiveTreadCells=math.max(g.maxActiveTreadCells,topo.activeCount)
    end
    g.nominalTreadDepth = math.max(finiteNumber(physical.treadDepthM, 0.006), 0.001)
    local meanRemainingDepth = 0
    for zone = 1, 3 do
        meanRemainingDepth = meanRemainingDepth + clamp(
            finiteNumber(data.tread_remaining_depth_m[zone], g.nominalTreadDepth),
            getNonWearableTreadReserveM(g.nominalTreadDepth), g.nominalTreadDepth)
    end
    meanRemainingDepth = meanRemainingDepth / 3
    g.simMeanDepth = math.max(meanRemainingDepth, M._tread1D.minimumSimDepthM)
    local meanTopo=M._tread1D.getCellTopologyForDepth(meanRemainingDepth,physical,true,g._topologyScratch[4])
    g.firstCellDepth = meanTopo.surfacePartialThicknessM
    g.gripDepthDecayM = math.max(finiteNumber(physical and physical.gripDepthDecayM, M._tread1D.gripDepthDecayM), 0.0001)

    g.physicalProfile = physical
    g.treadVoidRatio = clamp(finiteNumber(physical.treadVoidRatio, 0), 0, 0.60)
    g.grooveFloorVoidRatio = clamp(finiteNumber(physical.grooveFloorVoidRatio, g.treadVoidRatio), 0, g.treadVoidRatio)
    g.freshGrooveDepthM = M._treadGrooveGeometry.getFreshGrooveDepthM(physical, g.nominalTreadDepth)
    g.currentSurfaceVoidRatio = M._treadGrooveGeometry.getCurrentSurfaceVoidRatio(
        physical, g.nominalTreadDepth, meanRemainingDepth)
    g.surfaceLandFraction = clamp(1 - g.currentSurfaceVoidRatio, 0.05, 1.0)
    -- grooved-road hard-ground boundary. The remaining rubber land carries
    -- higher local pressure, so missing plan area is only PARTLY removed from contact
    -- conductance: G/Gsolid = land^(1-beta). beta=0.50 is [TG-E7], research-guided by
    -- the rough-contact power-law evidence [TG-R11], not a measured tyre-road constant.
    g.roadGroundContactPressureExponent = clamp(
        finiteNumber(physical.roadGroundContactPressureExponent, 1.0), 0, 1)
    g.roadGroundConductanceScale = g.surfaceLandFraction
        ^ (1 - g.roadGroundContactPressureExponent)
    g.volumeVoidRatio = M._treadGrooveGeometry.getCurrentVolumeVoidRatio(
        physical, g.nominalTreadDepth, meanRemainingDepth)
    g.structuralReserveM = M._treadGrooveGeometry.getReserveM(physical, g.nominalTreadDepth)
    g.postGrooveWearableM = math.max(g.nominalTreadDepth - g.freshGrooveDepthM - g.structuralReserveM, 0)
    g.configuredPostGrooveWearableM = math.max(
        finiteNumber(physical.postGrooveWearableM, g.postGrooveWearableM), 0)
    g.grooveGeometryClosureErrorM = g.postGrooveWearableM - g.configuredPostGrooveWearableM
    g.rubberFillFraction = 1 - g.volumeVoidRatio
    material = material or M._physicalThermal.getEffectiveTreadMaterial(nil)
    g.rubberConductivity = math.max(finiteNumber(material.conductivity, M._physicalThermal.rubberConductivity), 0.02)
    g.rubberDensity = math.max(finiteNumber(material.density, M._physicalThermal.rubberDensity), 100)
    g.rubberCp = math.max(finiteNumber(material.cp, M._physicalThermal.rubberCp), 100)
    g.rubberMaterialClass = material.classKey or "standard"
    g.rubberMaterialSource = material.source or "profile-direct"
    data._thermalZoneGeometryScratch=type(data._thermalZoneGeometryScratch)=="table" and data._thermalZoneGeometryScratch or {{},{},{}}
    g.zoneCellGeometry=data._thermalZoneGeometryScratch
    g.maxActiveTreadCells=1
    for z=1,3 do
        g.zoneCellGeometry[z]=M._tread1D.buildZoneCellGeometry(data,physical,z,g.treadArea/3,g.rubberDensity,g.rubberCp,g.zoneCellGeometry[z])
        g.activeTreadCellsByZone[z]=g.zoneCellGeometry[z].activeCount
        g.maxActiveTreadCells=math.max(g.maxActiveTreadCells,g.zoneCellGeometry[z].activeCount)
    end
    data.tyre_tread_area_m2=g.treadArea
    g.fullFirstCellMass = g.treadArea * g.firstCellDepth * g.rubberDensity
    local firstCellFill = M._treadGrooveGeometry.getCellRubberFillFraction(
        physical, g.nominalTreadDepth, meanRemainingDepth, 1, g.treadCells)
    g.firstCellMass = g.fullFirstCellMass * firstCellFill
    g.thinSurfaceHeatCapacity = math.max(g.firstCellMass * g.rubberCp, 1)
    g.fullTreadMass = g.treadArea * g.simMeanDepth * g.rubberDensity
    g.treadMass = g.fullTreadMass * g.rubberFillFraction
    g.skinHeatCapacity = math.max(g.treadMass * g.rubberCp, 1)
    g.fullSkinHeatCapacity = math.max(g.fullTreadMass * g.rubberCp, 1)

    g.coreReferenceTreadDepthM = math.max(finiteNumber(physical.legacyTreadDepthM, g.nominalTreadDepth), 0.001)
    g.explicitTreadMigrationDepthM = math.max(g.nominalTreadDepth - g.coreReferenceTreadDepthM, 0)
    local referenceSolidTreadCapacity = g.treadArea * g.coreReferenceTreadDepthM * g.rubberDensity * g.rubberCp
    local coreCapacityScale = math.max(finiteNumber(physical.coreCapacityScale, 1.0), 0.5)
    g.coreHeatCapacityBeforeTreadMigration = math.max(
        referenceSolidTreadCapacity * 2.2 + 3500, M._physicalThermal.minCoreCapacity) * coreCapacityScale
    g.coreMigratedToTreadCapacityJPerK = g.treadArea * g.explicitTreadMigrationDepthM * g.rubberDensity * g.rubberCp
    g.coreHeatCapacity = math.max(
        g.coreHeatCapacityBeforeTreadMigration - g.coreMigratedToTreadCapacityJPerK,
        M._physicalThermal.minCoreCapacity)

    g.grooveReferenceWidthM = math.max(finiteNumber(physical.representativeGrooveWidthM, 0.012), 0.002)
    g.grooveAirflowEffectiveness = clamp(finiteNumber(physical.grooveAirflowEffectiveness, 0), 0, 1.5)
    g.grooveForcedConvectionSpeedCapMps = math.max(finiteNumber(physical.grooveForcedConvectionSpeedCapMps, 166.6666667), 0)
    g.grooveSidewallAreaScale = math.max(finiteNumber(physical.grooveSidewallAreaScale, 1.0), 0)
    g.activeGrooveDepthM = M._treadGrooveGeometry.getCurrentActiveGrooveDepthM(
        physical, g.nominalTreadDepth, meanRemainingDepth)
    g.grooveDepthFraction = g.freshGrooveDepthM > 1e-9 and clamp(g.activeGrooveDepthM / g.freshGrooveDepthM, 0, 1) or 0
    local freshSurfaceVoid = math.max(g.treadVoidRatio, 0)
    local grooveLength = freshSurfaceVoid > 0 and (g.treadArea * freshSurfaceVoid / g.grooveReferenceWidthM) or 0
    local currentWidth = freshSurfaceVoid > 1e-9
        and g.grooveReferenceWidthM * g.currentSurfaceVoidRatio / freshSurfaceVoid or 0
    local floorWidth = freshSurfaceVoid > 1e-9
        and g.grooveReferenceWidthM * g.grooveFloorVoidRatio / freshSurfaceVoid or 0
    local halfWidthDelta = math.max(currentWidth - floorWidth, 0) * 0.5
    local slantDepth = math.sqrt(g.activeGrooveDepthM * g.activeGrooveDepthM + halfWidthDelta * halfWidthDelta)
    g.currentGrooveOpeningWidthM = currentWidth
    g.grooveTaperHalfAngleDeg = g.activeGrooveDepthM > 1e-9
        and math.deg(math.atan(halfWidthDelta / g.activeGrooveDepthM)) or 0
    g.grooveWallArea = (g.activeGrooveDepthM > 0 and grooveLength > 0) and (
        2 * grooveLength * slantDepth * g.grooveSidewallAreaScale) or 0
    g.safeLoad = math.max(finiteNumber(loadRaw, 0), 0)
    g.actualPressure = math.max(finiteNumber(pressurePa, OPTIMAL_PRESSURE), 0)
    g.safePressure = math.max(g.actualPressure, MIN_NUMERIC_PRESSURE_PSI * PSI_TO_PA)
    g.safeSpeed = math.max(finiteNumber(groundSpeed, 0), 0)
    g.safeAirspeed = math.max(finiteNumber(airspeed, g.safeSpeed), 0)
    g.safeSlipSpeed = clamp(finiteNumber(combinedSlipSpeed, 0), 0, M._physicalThermal.maxSlipSpeed)
    g.safeLongitudinalSlip = math.max(finiteNumber(longitudinalSlipSpeed, 0), 0)
    g.safeLateralSlip = math.max(finiteNumber(lateralSlipSpeed, 0), 0)
    g.groundMu = clamp(finiteNumber(groundModel.staticFrictionCoefficient, 1), 0.05, 3.0)
    g.weights = CalcBiasWeights(loadBias)

    local cavityStatic = type(data.cavity_static) == "table" and data.cavity_static or nil
    local sidewallHeightM = finiteNumber(cavityStatic and cavityStatic.sidewallHeightM, g.safeWidth * 0.50)
    local familyStructure = M._sportPhysicalStiffness and M._sportPhysicalStiffness.familyBaseStructure or nil
    local familyCfg = familyStructure and familyStructure[g.rubberMaterialClass] or nil
    local familySidewallScale = finiteNumber(familyCfg and familyCfg.sideSpring, 1.0)
    local liveSidewallScale = finiteNumber(data.sidewall_live_spring_scale, familySidewallScale)
    local contactMeta
    g.groundContactFactor, g.contactPatchArea, g.contactPatchRatio, contactMeta = CalculateGroundContact(
        g.safeLoad, g.actualPressure, g.safeWidth, g.safeRadius, sidewallHeightM, liveSidewallScale)
    contactMeta = type(contactMeta) == "table" and contactMeta or {}
    g.contactPatchRawArea = math.max(finiteNumber(contactMeta.rawArea, g.contactPatchArea), 0)
    g.contactPatchMaxArea = math.max(finiteNumber(contactMeta.maxArea, g.contactPatchArea), 0.005)
    g.contactEffectivePressurePa = math.max(finiteNumber(contactMeta.effectivePressurePa, g.safePressure), 1000)
    g.contactCarcassPressurePa = math.max(finiteNumber(contactMeta.carcassPressurePa, 0), 0)
    g.contactCarcassSidewallScale = finiteNumber(contactMeta.sidewallScale, liveSidewallScale)
    g.contactCarcassAspectRatio = finiteNumber(contactMeta.aspectRatio, sidewallHeightM / math.max(g.safeWidth, 0.001))
    g.contactPatchSaturationRatio = clamp(finiteNumber(contactMeta.saturationRatio, 1.0), 0, 1)
    g.contactPatchArea = clamp(finiteNumber(g.contactPatchArea, 0), 0.0, 0.15)
    g.footprintLength = clamp(g.contactPatchArea / math.max(g.safeWidth, 0.001), 0.0, math.pi * g.safeRadius)
    g.nominalWheelLoad = math.max((vehicleMass or 1500) * 9.81 / math.max(activeWheelCount or 4, 1), 1)
    g.loadRatio = math.max(g.safeLoad / g.nominalWheelLoad, 0.05)
    g.pressureFactor = clamp((OPTIMAL_PRESSURE / g.safePressure) ^ 0.65, 0.55, 1.90)
    return g
end

M._ensureWheelCavityStatic = function(data, wheelID, geom)
    if type(data) ~= "table" or type(geom) ~= "table" then return nil end
    local cfg = M._physicalThermal.wheelCavity or {}
    local atmospherePa = GetAmbientPressurePa()
    CaptureLivePressureReferenceIfNeeded(wheelID)
    local coldReferenceAbsolutePa, coldReferenceGaugePa, referenceSource = GetConfiguredPressureReferencePa(wheelID)
    local cachedReference = wheelPressureReferenceCache[wheelID]
    local coldReferenceTempC = finiteNumber(cachedReference and cachedReference.coldReferenceTempC, ENV_TEMP)

    local existing = type(data.cavity_static) == "table" and data.cavity_static or nil
    local sourceCoreBudgetJPerK = math.max(finiteNumber(geom.coreHeatCapacity, M._physicalThermal.minCoreCapacity), 1)
    if existing
        and finiteNumber(existing.thermalNetworkRevision, 0) >= 5
        and finiteNumber(existing.sidewallTotalCapacityJPerK, nil) ~= nil
        and finiteNumber(existing.crownCoreCapacityJPerK, nil) ~= nil
        and math.abs(finiteNumber(existing.sourceCoreBudgetJPerK, -1) - sourceCoreBudgetJPerK) < 0.5
        and math.abs(finiteNumber(existing.coldReferenceGaugePa, -1) - coldReferenceGaugePa) < 50 then
        return existing
    end

    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local wd = getWheelDefForBrush(wheelID)
    local runtimeTyreRadius = math.max(finiteNumber(geom.safeRadius, 0.33), 0.05)
    local runtimeTyreWidth = math.max(finiteNumber(geom.safeWidth, 0.20), 0.04)
    local runtimeHubRadius = finiteNumber(wr and wr.hubRadius, finiteNumber(wd and wd.hubRadius, runtimeTyreRadius * 0.68))
    runtimeHubRadius = clamp(runtimeHubRadius, 0.03, math.max(runtimeTyreRadius - 0.005, 0.031))

    local nominalThermalGeom = getNominalMetricTyreGeometry(wheelID)
    local tyreRadius = nominalThermalGeom and math.max(nominalThermalGeom.nominalOuterRadiusM, 0.05)
        or runtimeTyreRadius
    local tyreWidth = nominalThermalGeom and math.max(nominalThermalGeom.sectionWidthM, 0.04)
        or runtimeTyreWidth
    local hubRadius = nominalThermalGeom and clamp(nominalThermalGeom.rimRadiusM, 0.03, math.max(tyreRadius - 0.005, 0.031))
        or runtimeHubRadius
    local sidewallHeight = nominalThermalGeom
        and math.max(nominalThermalGeom.sectionWidthM * nominalThermalGeom.aspectRatio, 0.008)
        or math.max(tyreRadius - hubRadius, 0.008)
    local meanCavityRadius = math.max((tyreRadius + hubRadius) * 0.5, 0.04)

    local cavityWidth = tyreWidth * clamp(finiteNumber(cfg.cavityWidthFraction, 0.80), 0.45, 1.0)
    local cavityHeight = sidewallHeight * clamp(finiteNumber(cfg.cavityHeightFraction, 0.70), 0.35, 1.0)
    local cavityCrossSection = math.pi * math.max(cavityWidth * 0.5, 0.002) * math.max(cavityHeight, 0.003)
    local cavityVolume = clamp(cavityCrossSection * 2 * math.pi * meanCavityRadius, 0.002, 0.30)

    local gasR = math.max(finiteNumber(cfg.airGasConstantJkgK, 287.05), 1)
    local coldK = clamp(coldReferenceTempC + 273.15, 180, 700)
    local sealedMass = math.max(coldReferenceAbsolutePa * cavityVolume / (gasR * coldK), 0.005)
    local gasCapacity = clamp(sealedMass * math.max(finiteNumber(cfg.airCvJkgK, 718), 100),
        finiteNumber(cfg.minimumGasCapacityJPerK, 5), finiteNumber(cfg.maximumGasCapacityJPerK, 5000))

    local refR = math.max(finiteNumber(cfg.rimReferenceRadiusM, 0.23), 0.05)
    local refW = math.max(finiteNumber(cfg.rimReferenceWidthM, 0.225), 0.05)
    local rimMass = math.max(finiteNumber(cfg.rimReferenceMassKg, 9.0), 1.0)
        * (hubRadius / refR) ^ clamp(finiteNumber(cfg.rimMassRadiusExponent, 1.45), 0.2, 3.0)
        * (tyreWidth / refW) ^ clamp(finiteNumber(cfg.rimMassWidthExponent, 0.45), 0.0, 2.0)
    rimMass = clamp(rimMass, finiteNumber(cfg.rimMinMassKg, 3.5), finiteNumber(cfg.rimMaxMassKg, 30.0))
    local rimCapacity = math.max(rimMass * math.max(finiteNumber(cfg.rimEffectiveCpJkgK, 720), 100),
        finiteNumber(cfg.rimMinimumCapacityJPerK, 2500))
    local rimArea = math.max((2 * math.pi * hubRadius * tyreWidth + 1.35 * math.pi * hubRadius * hubRadius)
        * clamp(finiteNumber(cfg.rimAreaScale, 0.88), 0.25, 2.0), 0.06)

    local cavityFacingCrownArea = math.max(2 * math.pi * meanCavityRadius * cavityWidth, 0.03)
    local sidewallMeanRadius = math.max((tyreRadius + hubRadius) * 0.5, 0.04)
    local sidewallArea = math.max(2 * (2 * math.pi * sidewallMeanRadius * sidewallHeight), 0.02)
    local sidewallThickness = clamp(finiteNumber(cfg.sidewallEquivalentThicknessM, 0.0060), 0.002, 0.020)
    local sidewallRawCapacity = clamp(
        sidewallArea * sidewallThickness
            * math.max(finiteNumber(geom.rubberDensity, M._physicalThermal.rubberDensity), 500)
            * math.max(finiteNumber(geom.rubberCp, M._physicalThermal.rubberCp), 500),
        finiteNumber(cfg.sidewallMinTotalCapacityJPerK, 1400),
        finiteNumber(cfg.sidewallMaxTotalCapacityJPerK, 9000))

    local oldLumpedCoreCapacity = math.max(finiteNumber(geom.coreHeatCapacity, M._physicalThermal.minCoreCapacity), 1)
    local maxSidewallFraction = clamp(finiteNumber(cfg.sidewallMaxFractionOfOldCoreCapacity, 0.80), 0.05, 0.95)
    local sidewallTotalCapacity = math.min(sidewallRawCapacity, oldLumpedCoreCapacity * maxSidewallFraction)
    local crownCoreCapacity = math.max(oldLumpedCoreCapacity - sidewallTotalCapacity, oldLumpedCoreCapacity * (1 - maxSidewallFraction))

    local coreSidewallConductance = math.max(
        finiteNumber(cfg.coreSidewallBaseConductanceWPerK, 3.0)
            * clamp((sidewallArea / 0.20)
                ^ clamp(finiteNumber(cfg.coreSidewallAreaExponent, 0.50), 0, 1.5), 0.60, 1.60),
        0.10)

    local sectionAspect = sidewallHeight / math.max(tyreWidth, 0.001)
    local shoulderWidthFactor = clamp(math.sqrt(1 + sectionAspect * sectionAspect), 1.0,
        finiteNumber(cfg.treadShoulderCoolingMaxWidthFactor, 1.30))
    local treadCoolingWidth = tyreWidth * shoulderWidthFactor
    local shoulderEquivalentHeightEach = math.max((treadCoolingWidth - tyreWidth) * 0.5, 0)
    local sidewallExternalHeight = math.max(sidewallHeight - shoulderEquivalentHeightEach, sidewallHeight * 0.20)
    local sidewallExternalArea = math.max(2 * (2 * math.pi * sidewallMeanRadius * sidewallExternalHeight), 0.01)

    existing = {
        thermalNetworkRevision = 5,
        sourceCoreBudgetJPerK = sourceCoreBudgetJPerK,
        cavityVolumeM3 = cavityVolume,
        sealedAirMassKg = sealedMass,
        gasCapacityJPerK = gasCapacity,
        rimCapacityJPerK = rimCapacity,
        rimAreaM2 = rimArea,
        cavityFacingCrownAreaM2 = cavityFacingCrownArea,
        sidewallAreaM2 = sidewallArea,
        sidewallExternalAreaM2 = sidewallExternalArea,
        sidewallTotalCapacityJPerK = sidewallTotalCapacity,
        sidewallOuterCapacityJPerK = sidewallTotalCapacity * 0.5,
        sidewallInnerCapacityJPerK = sidewallTotalCapacity * 0.5,
        crownCoreCapacityJPerK = crownCoreCapacity,
        oldLumpedCoreCapacityJPerK = oldLumpedCoreCapacity,
        coreSidewallConductanceWPerK = coreSidewallConductance,
        sidewallHeightM = sidewallHeight,
        geometrySource = nominalThermalGeom and tostring(nominalThermalGeom.source or "tyre-part-metric-size") or "runtime-fallback",
        sidewallAspectRatio = sectionAspect,
        treadCoolingWidthM = treadCoolingWidth,
        treadCoolingWidthFactor = shoulderWidthFactor,
        hubRadiusM = hubRadius,
        tyreRadiusM = tyreRadius,
        tyreWidthM = tyreWidth,
        coldReferenceGaugePa = coldReferenceGaugePa,
        coldReferenceTempC = coldReferenceTempC,
    }
    data.cavity_static = existing
    data.cavity_sealed_air_mass_kg = sealedMass
    data.cavity_volume_l = cavityVolume * 1000
    data.cavity_gas_capacity_j_k = gasCapacity
    data.rim_heat_capacity_j_k = rimCapacity
    return existing
end

M._calculatePreheatHotCavityState = function(data, wheelID, workingTarget)
    if type(data) ~= "table" then return nil end
    local ambient = finiteNumber(ENV_TEMP, 20)
    local working = finiteNumber(workingTarget, ambient)
    local cfg = M._physicalThermal or {}
    local hotFraction = clamp(finiteNumber(cfg.preheatHotCavityFraction, 0.50), 0, 1.2)
    local hotAirC = ambient + (working - ambient) * hotFraction
    local currentAirC = finiteNumber(data.air_temp, ambient)

    local atmospherePa = GetAmbientPressurePa()
    local liveGaugePa, liveAbsolutePa, liveSource = ReadActualPressureGroupGaugePa(wheelID)
    if liveAbsolutePa == nil then
        local fallbackAbsolutePa, fallbackGaugePa, fallbackSource = GetConfiguredPressureReferencePa(wheelID)
        liveAbsolutePa = fallbackAbsolutePa
        liveGaugePa = fallbackGaugePa
        liveSource = "fallback:" .. tostring(fallbackSource)
    end

    local currentK = clamp(currentAirC + 273.15, 150, 1000)
    local hotK = clamp(hotAirC + 273.15, 150, 1000)
    local hotAbsolutePa = liveAbsolutePa * (hotK / currentK)
    local hotGaugePa = math.max(hotAbsolutePa - atmospherePa, 0)

    return {
        airTempC = hotAirC,
        previousAirTempC = currentAirC,
        hotAbsolutePa = hotAbsolutePa,
        hotGaugePa = hotGaugePa,
        hotGaugePsi = hotGaugePa / PSI_TO_PA,
        liveGaugePsi = math.max(finiteNumber(liveGaugePa, 0), 0) / PSI_TO_PA,
        referenceSource = liveSource or "pressureGroup-unavailable",
    }
end

M._applyPreheatHotCavityState = function(data, wheelID, workingTarget, applyPressureDelta)
    local state = M._calculatePreheatHotCavityState(data, wheelID, workingTarget)
    if not state then return false end

    local ambient = finiteNumber(ENV_TEMP, 20)
    local previousAirTempC = state.previousAirTempC
    data.air_temp = state.airTempC

    local cfg = M._physicalThermal or {}
    local rimFraction = clamp(finiteNumber(cfg.preheatHotRimFractionOfGasDelta, 1.0), 0, 1.2)
    data.rim_temp = ambient + (state.airTempC - ambient) * rimFraction
    local coreT = finiteNumber(data.temp and data.temp[4], ambient)
    local sidewallSoakT = (coreT + state.airTempC) * 0.5
    data.sidewall_outer_temp = sidewallSoakT
    data.sidewall_inner_temp = sidewallSoakT
    data.sidewall_semantics_revision = 2
    data.sidewall_outer_heat_pending_j = 0
    data.sidewall_inner_heat_pending_j = 0
    data.sidewall_heat_pending_j = 0

    data.preheat_hot_air_target_c = state.airTempC
    data.preheat_hot_pressure_target_psi = state.hotGaugePsi
    data.preheat_cold_pressure_reference_psi = state.liveGaugePsi
    data.preheat_pressure_reference_temp_c = previousAirTempC
    data.preheat_pressure_reference_source = state.referenceSource
    data.cavity_thermal_accumulator_s = 0

    if applyPressureDelta == false then
        data.pressure_control_state = "preheat-thermal-state-pressure-deferred"
        UpdatePressureReadOnlyTelemetry(wheelID)
        return true, state
    end

    local applied = ApplyThermalPressureDelta(
        wheelID, previousAirTempC, state.airTempC, "preheat")
    UpdatePressureReadOnlyTelemetry(wheelID)
    if applied then
        data.pressure_control_state = "beamng-native+thermal-live-delta:preheat"
    end
    return applied, state
end

M._applySoakedPreheatCavityState = function(data, wheelID, target, applyPressureDelta)
    if type(data) ~= "table" then return false end
    local previousAirTempC = finiteNumber(data.air_temp, ENV_TEMP)
    target = clamp(finiteNumber(target, ENV_TEMP), -100, 500)

    local atmospherePa = GetAmbientPressurePa()
    local liveGaugePa, liveAbsolutePa, liveSource = ReadActualPressureGroupGaugePa(wheelID)
    if liveAbsolutePa == nil then
        local fallbackAbsolutePa, fallbackGaugePa, fallbackSource = GetConfiguredPressureReferencePa(wheelID)
        liveAbsolutePa = fallbackAbsolutePa
        liveGaugePa = fallbackGaugePa
        liveSource = "fallback:" .. tostring(fallbackSource)
    end
    local currentK = clamp(previousAirTempC + 273.15, 150, 1000)
    local hotK = clamp(target + 273.15, 150, 1000)
    local hotAbsolutePa = liveAbsolutePa * (hotK / currentK)
    local hotGaugePa = math.max(hotAbsolutePa - atmospherePa, 0)

    data.air_temp = target
    data.rim_temp = target
    data.sidewall_outer_temp = target
    data.sidewall_inner_temp = target
    data.sidewall_semantics_revision = 2
    data.sidewall_outer_heat_pending_j = 0
    data.sidewall_inner_heat_pending_j = 0
    data.sidewall_heat_pending_j = 0
    data.preheat_hot_air_target_c = target
    data.preheat_hot_pressure_target_psi = hotGaugePa / PSI_TO_PA
    data.preheat_cold_pressure_reference_psi = math.max(finiteNumber(liveGaugePa, 0), 0) / PSI_TO_PA
    data.preheat_pressure_reference_temp_c = previousAirTempC
    data.preheat_pressure_reference_source = liveSource or "pressureGroup-unavailable"
    data.cavity_thermal_accumulator_s = 0

    if applyPressureDelta == false then
        data.pressure_control_state = "preheat-soaked-pressure-deferred"
        UpdatePressureReadOnlyTelemetry(wheelID)
        return true
    end

    local applied = ApplyThermalPressureDelta(wheelID, previousAirTempC, target, "preheat-soaked")
    UpdatePressureReadOnlyTelemetry(wheelID)
    if applied then data.pressure_control_state = "beamng-native+thermal-live-delta:preheat-soaked" end
    return applied
end

M._pitStop = M._pitStop or {
    enabled = false,
    state = "off",
    message = "PIT MANAGER",
    durationS = 15.0,
    remainingS = 0,
    finishedHoldS = 0,
    stopThresholdKmh = 0.5,
    progress = 0,
    lastSpeedKmh = 0,
    stagedProfile = "auto",
    stagedSlickCompound = "medium",
    stagedRallySurface = "asphalt",
    stagedRallyCompound = "medium",
    stagedFrontPsi = nil,
    stagedRearPsi = nil,
    stagedPreheatMode = "quick",
    stagedPreheatTargetC = nil,
    stagedPreheatCornerTargets = nil,
    throttleLocked = false,
}

M._pitStop.getDefaultPreheatTarget = function()
    local total, count = 0, 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        local t = tonumber(getWheelPreheatTarget(wheelID))
        if t ~= nil then total, count = total + t, count + 1 end
    end
    if count > 0 then return total / count end
    return WORKING_TEMP >= 0 and WORKING_TEMP or 70
end

M._pitStop.getStagedPreheatDefault = function()
    if WORKING_TEMP >= 0 then return clamp(WORKING_TEMP, -100, 500) end
    local p = M._pitStop
    local profileId = string.lower(tostring(p.stagedProfile or "auto"))

    local function profileTarget(profile)
        return profile and tonumber(profile.workingTemp) or nil
    end

    if profileId == "race" then
        local variants = (M._slickCompounds and M._slickCompounds.variants) or {}
        local variant = variants[p.stagedSlickCompound or "medium"] or variants.medium
        return clamp(profileTarget(variant and variant.profile) or 105, -100, 500)
    elseif profileId == "rally" then
        local surfaces = (M._rallyCompounds and M._rallyCompounds.surfaces) or {}
        local surface = surfaces[p.stagedRallySurface or "asphalt"] or surfaces.asphalt
        local variants = surface and surface.variants or {}
        local variant = variants[p.stagedRallyCompound or "medium"] or variants.medium
        return clamp(profileTarget(variant and variant.profile) or 80, -100, 500)
    elseif profileId ~= "auto" then
        return clamp(profileTarget(TYRE_PROFILES[profileId]) or p.getDefaultPreheatTarget(), -100, 500)
    end

    local total, count = 0, 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        local detected = RT.wheelTyreProfiles and RT.wheelTyreProfiles[wheelID] or nil
        local profile = detected and detected.profile or nil
        if profile and profile.id == "race" then
            local variants = (M._slickCompounds and M._slickCompounds.variants) or {}
            local variant = variants[p.stagedSlickCompound or "medium"] or variants.medium
            profile = variant and variant.profile or profile
        elseif profile and (profile.id == "rally_asphalt" or profile.id == "rally_gravel") then
            local surfaceId = profile.id == "rally_gravel" and "gravel" or "asphalt"
            local surfaces = (M._rallyCompounds and M._rallyCompounds.surfaces) or {}
            local surface = surfaces[surfaceId]
            local variants = surface and surface.variants or {}
            local variant = variants[p.stagedRallyCompound or "medium"] or variants.medium
            profile = variant and variant.profile or profile
        end
        local t = profileTarget(profile)
        if t ~= nil then total, count = total + t, count + 1 end
    end
    if count > 0 then return clamp(total / count, -100, 500) end
    return clamp(p.getDefaultPreheatTarget(), -100, 500)
end

M._pitStop.resetStagedPreheatTargetToPreset = function()
    local p = M._pitStop
    if p.stagedPreheatCornerTargets == nil then
        p.stagedPreheatTargetC = p.getStagedPreheatDefault()
    end
    return p.stagedPreheatTargetC
end

M._pitStop.copyAppliedSelectionToStage = function()
    local p = M._pitStop
    M._axlePressureOverride.captureInitialTune(false)
    p.stagedProfile = MANUAL_TYRE_PROFILE or "auto"
    p.stagedSlickCompound = M._slickCompounds.getPreset()
    p.stagedRallySurface = M._rallyCompounds.getSurfacePreset()
    p.stagedRallyCompound = M._rallyCompounds.getCompoundPreset()
    p.stagedFrontPsi = M._axlePressureOverride.frontPsi
    p.stagedRearPsi = M._axlePressureOverride.rearPsi
    p.stagedPreheatMode = "quick"
    p.stagedPreheatTargetC = p.getStagedPreheatDefault()
    p.stagedPreheatCornerTargets = nil
end

M._pitStop.forceThrottleZero = function()
    local p = M._pitStop
    local filter = (type(FILTER_DIRECT) == "number" and FILTER_DIRECT or 2)
    if input and type(input.event) == "function" then
        pcall(input.event, "throttle", 0, filter)
        p.throttleLocked = true
    end
end

M._pitStop.releaseThrottle = function()
    local p = M._pitStop
    if not p.throttleLocked then return end
    local filter = (type(FILTER_DIRECT) == "number" and FILTER_DIRECT or 2)
    if input and type(input.event) == "function" then
        pcall(input.event, "throttle", 0, filter)
    end
    p.throttleLocked = false
end

M._pitStop.getVehicleSpeedKmh = function()
    local ok, velocity = pcall(function() return obj:getVelocity() end)
    if not ok or velocity == nil then return 0 end
    local okLen, speed = pcall(function() return velocity:length() end)
    if not okLen then return 0 end
    return math.abs(finiteNumber(speed, 0)) * 3.6
end

M._pitStop.markWaiting = function()
    local p = M._pitStop
    if not p.enabled or p.state == "countdown" then return end
    local speedKmh = p.getVehicleSpeedKmh()
    p.lastSpeedKmh = speedKmh
    if speedKmh < p.stopThresholdKmh then
        p.state = "ready"
        p.message = "PIT READY"
        p.progress = 1
    else
        p.state = "waiting"
        p.message = "WAITING PIT STOP"
        p.progress = 1
    end
    p.finishedHoldS = 0
end

M._pitStop.setEnabled = function(enabled)
    local p = M._pitStop
    enabled = enabled == true
    if not enabled then
        p.enabled = false
        p.state = "off"
        p.message = "PIT MANAGER"
        p.remainingS = 0
        p.finishedHoldS = 0
        p.progress = 0
        p.releaseThrottle()
        p.copyAppliedSelectionToStage()
        return false
    end
    if not p.enabled then
        p.copyAppliedSelectionToStage()
    end
    p.enabled = true
    p.remainingS = 0
    p.finishedHoldS = 0
    p.markWaiting()
    return true
end

M._pitStop.stageProfile = function(profileId)
    local p = M._pitStop
    profileId = string.lower(tostring(profileId or "auto"))
    if profileId ~= "auto" and profileId ~= "rally" and not TYRE_PROFILES[profileId] then
        return false
    end
    p.stagedProfile = profileId
    p.resetStagedPreheatTargetToPreset()
    p.markWaiting()
    return profileId
end

M._pitStop.stageSlickCompound = function(compoundId)
    local p = M._pitStop
    compoundId = string.lower(tostring(compoundId or "medium"))
    if not ((M._slickCompounds and M._slickCompounds.variants) or {})[compoundId] then
        return false
    end
    p.stagedSlickCompound = compoundId
    p.resetStagedPreheatTargetToPreset()
    p.markWaiting()
    return compoundId
end

M._pitStop.stageRallySurface = function(surfaceId)
    local p = M._pitStop
    surfaceId = string.lower(tostring(surfaceId or "asphalt"))
    if not ((M._rallyCompounds and M._rallyCompounds.surfaces) or {})[surfaceId] then
        return false
    end
    p.stagedRallySurface = surfaceId
    p.resetStagedPreheatTargetToPreset()
    p.markWaiting()
    return surfaceId
end

M._pitStop.stageRallyCompound = function(compoundId)
    local p = M._pitStop
    compoundId = string.lower(tostring(compoundId or "medium"))
    local surface = M._rallyCompounds.getSurface(p.stagedRallySurface)
    if not (surface and surface.variants and surface.variants[compoundId]) then
        return false
    end
    p.stagedRallyCompound = compoundId
    p.resetStagedPreheatTargetToPreset()
    p.markWaiting()
    return compoundId
end

M._pitStop.stagePressure = function(axle, value)
    local p = M._pitStop
    axle = string.lower(tostring(axle or ""))
    if axle ~= "front" and axle ~= "rear" then return false end

    M._axlePressureOverride.captureInitialTune(false)
    local text = string.lower(tostring(value == nil and "" or value))
    local psi
    if text == "auto" or text == "" then
        psi = M._axlePressureOverride.getInitialTunePsi(axle)
    else
        psi = tonumber(value)
    end
    if psi == nil then return false end
    psi = math.max(psi, MIN_DYNAMIC_PRESSURE_PSI)

    if axle == "front" then p.stagedFrontPsi = psi else p.stagedRearPsi = psi end
    p.markWaiting()
    return psi
end

M._pitStop.stagePreheat = function(mode, targetC)
    local p = M._pitStop
    mode = normalisePreheatMode(mode)
    local target = tonumber(targetC)
    if target == nil then target = p.stagedPreheatTargetC or p.getStagedPreheatDefault() end
    target = clamp(target, -100, 500)
    p.stagedPreheatMode = mode
    p.stagedPreheatTargetC = target
    p.stagedPreheatCornerTargets = nil
    p.markWaiting()
    return mode, target
end

M._pitStop.stagePreheatAdvanced = function(mode, cornerTargets)
    local p = M._pitStop
    mode = normalisePreheatMode(mode)
    local targets = M._advancedPreheat.normaliseTargets(cornerTargets)
    if not targets then return false end
    local fallback = tonumber(p.stagedPreheatTargetC) or p.getStagedPreheatDefault()
    for _, key in ipairs({"FL", "FR", "RL", "RR"}) do
        if targets[key] == nil then targets[key] = fallback end
    end
    p.stagedPreheatMode = mode
    p.stagedPreheatCornerTargets = targets
    p.stagedPreheatTargetC = (targets.FL + targets.FR + targets.RL + targets.RR) * 0.25
    p.markWaiting()
    return mode, targets
end

M._pitStop.resetWheelToFreshTyre = function(wheelID, data)
    if type(data) ~= "table" then return false end

    local detected = getWheelTyreProfile(wheelID)
    local physical = M._physicalThermal.getPhysicalProfile(detected and detected.profile)
    data.condition = 100
    M._tread1D.applyPresetDepthHealth(data, { zoneHealth = {1, 1, 1} }, physical)
    if M._tread1D and M._tread1D.setUniform then M._tread1D.setUniform(data, ENV_TEMP, physical) end
    data.surface_temp = {ENV_TEMP, ENV_TEMP, ENV_TEMP}
    data.surface_boundary_temp = {ENV_TEMP, ENV_TEMP, ENV_TEMP}
    data.temp = {ENV_TEMP, ENV_TEMP, ENV_TEMP, ENV_TEMP}
    data.flash_temp = ENV_TEMP
    if M._tread1D and M._tread1D.deriveTemps then M._tread1D.deriveTemps(data, physical) end
    data.temp[4] = ENV_TEMP

    if M._circumferential and M._circumferential.ensureState then
        local circ = M._circumferential.ensureState(data)
        circ.wearFeatures = {}
        circ.thermalFeatures = {}
        circ.pendingBulkEnergyJ = nil
        circ.pendingBulkCellEnergyJ = {}
        if M._circumferential.ensurePendingCells then
            M._circumferential.ensurePendingCells(circ, M._tread1D and M._tread1D.cells or 12)
        end
    end
    data.circumferential_contact_wear_anomaly_m = {0, 0, 0}
    data.circumferential_wear_feature_count = 0

    data.rally_block_edges = {
        {xp = 1, xn = 1, yp = 1, yn = 1},
        {xp = 1, xn = 1, yp = 1, yn = 1},
        {xp = 1, xn = 1, yp = 1, yn = 1},
    }
    data.rally_block_height_health = 1
    data.rally_block_active_edge_health = 1

    local pressureGroupID = GetPressureGroupID(wheelID)
    local initAbsolutePa = select(1, GetConfiguredPressureReferencePa(wheelID))
    local cachedWheel = wheelCache and wheelCache[wheelID] or nil
    if pressureGroupID ~= nil and initAbsolutePa ~= nil
       and not (cachedWheel and (cachedWheel.isTireDeflated or cachedWheel.isBroken)) then
        local ok = pcall(function()
            obj:setGroupPressure(pressureGroupID, math.max(initAbsolutePa, 1000))
        end)
        if ok then pressureSetterAvailable = true end
    end

    data.air_temp = ENV_TEMP
    data.rim_temp = ENV_TEMP
    data.sidewall_outer_temp = ENV_TEMP
    data.sidewall_inner_temp = ENV_TEMP
    data.sidewall_semantics_revision = 2
    data.sidewall_outer_heat_pending_j = 0
    data.sidewall_inner_heat_pending_j = 0
    data.sidewall_heat_pending_j = 0
    data.thermal_pressure_delta_psi = 0
    data.thermal_pressure_ratio = 1
    data.thermal_pressure_cumulative_delta_pa = 0
    data.thermal_pressure_pending_delta_pa = 0
    data.thermal_pressure_last_applied_temp_c = ENV_TEMP
    data.pressure_control_state = "pit-new-tyre-native-pressure"
    data.multi_rate_thermal_state = nil
    data.thermal_cache_force_publish = true
    data.b100_slow_cache_dirty = true
    data.preheat_mode_last_applied = "cold"
    data.preheat_target_c_last_applied = ENV_TEMP
    if M._thermalGripCacheByWheel then M._thermalGripCacheByWheel[wheelID] = nil end
    if M._pressureWheelBrush and M._pressureWheelBrush.slowCacheByWheel then M._pressureWheelBrush.slowCacheByWheel[wheelID] = nil end

    if M._careerWearPersistence and M._careerWearPersistence.applied then
        M._careerWearPersistence.applied[wheelID] = true
    end
    wheelFlashGripState[wheelID] = nil
    UpdatePressureReadOnlyTelemetry(wheelID)
    return true
end

M._pitStop.finishTyreChange = function()
    local p = M._pitStop

    setTyreProfilePreset(p.stagedProfile)
    M._slickCompounds.setPreset(p.stagedSlickCompound)
    M._rallyCompounds.setSurfacePreset(p.stagedRallySurface)
    M._rallyCompounds.setCompoundPreset(p.stagedRallyCompound)

    --
    local previousFrontPsi = M._axlePressureOverride.frontPsi
    local previousRearPsi = M._axlePressureOverride.rearPsi
    M._axlePressureOverride.frontPsi = nil
    M._axlePressureOverride.rearPsi = nil

    local freshCount = 0
    for wheelID, _ in pairs((wheels and wheels.wheelRotators) or {}) do
        if p.resetWheelToFreshTyre(wheelID, tyreData[wheelID]) then
            freshCount = freshCount + 1
        end
    end

    local servicePreheatMode = normalisePreheatMode(p.stagedPreheatMode)
    local servicePreheatTargetC = tonumber(p.stagedPreheatTargetC) or p.getDefaultPreheatTarget()

    local serviceFrontPsi = p.stagedFrontPsi ~= nil and p.stagedFrontPsi
        or previousFrontPsi or M._axlePressureOverride.getInitialTunePsi("front")
    local serviceRearPsi = p.stagedRearPsi ~= nil and p.stagedRearPsi
        or previousRearPsi or M._axlePressureOverride.getInitialTunePsi("rear")
    local heatedCount, pressureCount = preheatTyres(servicePreheatMode, servicePreheatTargetC, {
        coldFrontPsi = serviceFrontPsi,
        coldRearPsi = serviceRearPsi,
        pressureReason = "pit-stop-cold-fill-psi",
        cornerTargets = p.stagedPreheatCornerTargets,
    })

    p.releaseThrottle()
    p.state = "finished"
    p.message = "FINISHED"
    p.remainingS = 0
    p.progress = 1
    p.finishedHoldS = 5.0

    log("I", "luukstyrethermalsandwear", string.format(
        "RACING MODE pit stop complete: profile=%s slick=%s rally=%s/%s fresh=%d preheat=%s@%.1fC heated=%d coldPressureWheels=%d frontColdPsi=%s rearColdPsi=%s",
        tostring(p.stagedProfile), tostring(p.stagedSlickCompound),
        tostring(p.stagedRallySurface), tostring(p.stagedRallyCompound),
        freshCount, tostring(servicePreheatMode), servicePreheatTargetC, heatedCount, pressureCount,
        tostring(M._axlePressureOverride.frontPsi),
        tostring(M._axlePressureOverride.rearPsi)
    ))
    return freshCount
end

M._pitStop.request = function()
    local p = M._pitStop
    if not p.enabled or p.state == "countdown" then return false end

    local speedKmh = p.getVehicleSpeedKmh()
    p.lastSpeedKmh = speedKmh
    if speedKmh >= p.stopThresholdKmh then
        p.state = "must_stop"
        p.message = "STOP CAR COMPLETELY"
        p.progress = 0
        p.remainingS = 0
        p.finishedHoldS = 0
        return false
    end

    p.state = "countdown"
    p.message = "PIT STOP"
    p.remainingS = p.durationS
    p.progress = 0
    p.finishedHoldS = 0
    p.forceThrottleZero()
    return true
end

M._pitStop.update = function(dt, vehicleVelocity)
    local p = M._pitStop
    local safeDt = clamp(math.max(finiteNumber(dt, 0), 0), 0, 0.10)

    local speedKmh
    if vehicleVelocity ~= nil then
        local ok, length = pcall(function() return vehicleVelocity:length() end)
        speedKmh = ok and math.abs(finiteNumber(length, 0)) * 3.6 or 0
    else
        speedKmh = p.getVehicleSpeedKmh()
    end
    p.lastSpeedKmh = speedKmh

    if not p.enabled then return end

    if p.state == "must_stop" then
        if speedKmh < p.stopThresholdKmh then
            p.state = "ready"
            p.message = "PIT READY"
            p.progress = 1
        end
        return
    end

    if p.state == "countdown" then
        p.forceThrottleZero()
        p.remainingS = math.max(finiteNumber(p.remainingS, p.durationS) - safeDt, 0)
        p.progress = clamp(1 - p.remainingS / math.max(p.durationS, 0.001), 0, 1)
        if p.remainingS <= 0 then
            p.finishTyreChange()
        end
        return
    end

    if p.state == "finished" then
        p.finishedHoldS = math.max(finiteNumber(p.finishedHoldS, 0) - safeDt, 0)
        if p.finishedHoldS > 0 then return end
    end

    if speedKmh < p.stopThresholdKmh then
        p.state = "ready"
        p.message = "PIT READY"
        p.progress = 1
    else
        p.state = "waiting"
        p.message = "WAITING PIT STOP"
        p.progress = 1
    end
end

M._pitStop.reset = function()
    local p = M._pitStop
    p.releaseThrottle()
    p.enabled = false
    p.state = "off"
    p.message = "PIT MANAGER"
    p.remainingS = 0
    p.finishedHoldS = 0
    p.progress = 0
    p.lastSpeedKmh = 0
    p.copyAppliedSelectionToStage()
end

-- into the explicit sidewall/apex structural reservoir. Research ref: [R12].
-- Published component splits vary substantially with tyre construction and material
-- model, so 0.38 is a KTS reduced-order calibration anchor rather than a universal
-- physical percentage. Aspect scaling preserves the established trend that shorter,
-- stiffer sidewalls carry less cyclic deformation. Total rolling power is unchanged.
M._getSidewallRollingHeatShare = function(data, geom)
    local cfg = M._physicalThermal.wheelCavity or {}
    local static = type(data) == "table" and data.cavity_static or nil
    local aspect = math.max(finiteNumber(static and static.sidewallAspectRatio, 0.50), 0.05)
    local refAspect = math.max(finiteNumber(cfg.sidewallReferenceAspect, 0.50), 0.05)
    local share = math.max(finiteNumber(cfg.sidewallRollingLossReferenceShare, 0.38), 0)
        * (aspect / refAspect) ^ clamp(finiteNumber(cfg.sidewallAspectLossExponent, 0.30), 0, 1.5)
    local treadShare = clamp(finiteNumber(M._tread1D.treadRollingHeatShare, 0.60), 0, 0.90)
    local coreReserve = clamp(finiteNumber(cfg.rollingCoreMinimumShare, 0.05), 0, 0.50)
    local maximumAllowed = math.max(1 - treadShare - coreReserve, 0)
    return clamp(share,
        math.min(finiteNumber(cfg.sidewallRollingLossMinShare, 0.30), maximumAllowed),
        math.min(finiteNumber(cfg.sidewallRollingLossMaxShare, 0.35), maximumAllowed))
end

M._getActualSidewallHeatSplit = function(rollingZoneWeights, flexWeights, crossTreadState)
    local cfg = M._physicalThermal.wheelCavity or {}
    local rollOuter = math.max(finiteNumber(rollingZoneWeights and rollingZoneWeights[1], 1 / 3), 0)
    local rollInner = math.max(finiteNumber(rollingZoneWeights and rollingZoneWeights[3], 1 / 3), 0)
    local flexOuter = math.max(finiteNumber(flexWeights and flexWeights[1], rollOuter), 0)
    local flexInner = math.max(finiteNumber(flexWeights and flexWeights[3], rollInner), 0)

    local flexProxy = clamp(finiteNumber(crossTreadState and crossTreadState.flexStrainProxy, 0), 0, 1.5)
    local blend = clamp(flexProxy, 0, 1)
    local outerBase = rollOuter * (1 - 0.55 * blend) + flexOuter * (0.55 * blend)
    local innerBase = rollInner * (1 - 0.55 * blend) + flexInner * (0.55 * blend)
    local baseSum = outerBase + innerBase
    if baseSum <= 1e-9 then outerBase, innerBase, baseSum = 0.5, 0.5, 1 end
    outerBase, innerBase = outerBase / baseSum, innerBase / baseSum

    local exponent = 1 + math.max(finiteNumber(cfg.sidewallFlexBiasExponentGain, 1.25), 0) * flexProxy
    local outerRaw = math.max(outerBase, 1e-6) ^ exponent
    local innerRaw = math.max(innerBase, 1e-6) ^ exponent
    local rawSum = outerRaw + innerRaw
    local outerShare = rawSum > 1e-9 and outerRaw / rawSum or 0.5
    local minShare = clamp(finiteNumber(cfg.sidewallMinPerSideHeatShare, 0.03), 0, 0.49)
    outerShare = clamp(outerShare, minShare, 1 - minShare)
    return outerShare, 1 - outerShare, flexProxy, exponent
end

M._updateWheelCavityThermals = function(data, wheelID, geom, brakeTemp, safeDt)
    if type(data) ~= "table" or type(geom) ~= "table" or safeDt <= 0 then return end
    local cfg = M._physicalThermal.wheelCavity or {}
    local interval = math.max(finiteNumber(cfg.thermalUpdateIntervalS, 0.20), 0.05)
    data.cavity_thermal_accumulator_s = 0
    data.cavity_thermal_update_hz = 1 / interval
    local stepDt = clamp(finiteNumber(safeDt, interval), 0.0001,
        math.max(finiteNumber(cfg.thermalMaxCatchupS, 0.60), interval))

    local static = M._ensureWheelCavityStatic(data, wheelID, geom)
    if not static then return end
    local ambient = finiteNumber(ENV_TEMP, 20)
    local coreT = finiteNumber(data.temp and data.temp[4], ambient)

    if finiteNumber(data.sidewall_semantics_revision, 0) < 2 then
        local legacyOuter = finiteNumber(data.sidewall_outer_temp, coreT)
        local legacyInner = finiteNumber(data.sidewall_inner_temp, coreT)
        local migratedMean = (legacyOuter + legacyInner) * 0.5
        data.sidewall_outer_temp = migratedMean
        data.sidewall_inner_temp = migratedMean
        local legacyPending = math.max(finiteNumber(data.sidewall_heat_pending_j, 0), 0)
        data.sidewall_outer_heat_pending_j = math.max(finiteNumber(data.sidewall_outer_heat_pending_j, 0), 0) + legacyPending * 0.5
        data.sidewall_inner_heat_pending_j = math.max(finiteNumber(data.sidewall_inner_heat_pending_j, 0), 0) + legacyPending * 0.5
        data.sidewall_heat_pending_j = 0
        data.sidewall_semantics_revision = 2
    end

    local sideOuterT = finiteNumber(data.sidewall_outer_temp, coreT)
    local sideInnerT = finiteNumber(data.sidewall_inner_temp, coreT)
    local airT = finiteNumber(data.air_temp, ambient)
    local rimT = finiteNumber(data.rim_temp, ambient)
    local wr = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil

    local tyreRadius = math.max(finiteNumber(static.tyreRadiusM, geom.safeRadius), 0.05)
    local wheelSurfaceSpeed = math.abs(finiteNumber(wr and wr.angularVelocity,
        finiteNumber(wheelCache[wheelID] and wheelCache[wheelID].angularVelocity, 0))) * tyreRadius

    -- Footprint/peristaltic cavity flow. Effective internal-air speed rises with
    -- real normal load and pressure-driven deflection, but remains capped at the
    -- measured ~0.30 road-speed order of magnitude.
    local deformationPump = math.max(geom.loadRatio, 0.05)
        ^ clamp(finiteNumber(cfg.cavityLoadFlowExponent, 0.55), 0, 1.5)
        * math.max(geom.pressureFactor, 0.05)
        ^ clamp(finiteNumber(cfg.cavityPressureFlowExponent, 0.65), 0, 1.5)
    local nominalFlowFraction = clamp(finiteNumber(cfg.cavityNominalFlowFraction, 0.16), 0.01, 0.30)
    local cavityFlowFraction = clamp(nominalFlowFraction * deformationPump,
        finiteNumber(cfg.cavityMinFlowFraction, 0.06),
        finiteNumber(cfg.cavityMaxFlowFraction, 0.30))
    local cavityFlowSpeed = wheelSurfaceSpeed * cavityFlowFraction
    local turbulenceRoot = math.sqrt(math.max(cavityFlowSpeed / nominalFlowFraction, 0))

    local crownArea = math.max(finiteNumber(static.cavityFacingCrownAreaM2, 0.35), 0.03)
    local crownAreaScale = clamp(crownArea / 0.35, 0.45, 2.0)
    local coreGasFlowH = (math.max(finiteNumber(cfg.coreCavityNaturalConductanceWPerK, 2.8), 0)
        + math.max(finiteNumber(cfg.coreCavityTurbulenceConductancePerSqrtMS, 0.95), 0) * turbulenceRoot)
        * crownAreaScale
    local equivalentExternalTyreH_Wm2K = 7.0 + 4.0 * math.sqrt(math.max(wheelSurfaceSpeed, 0))
        + 0.42 * math.max(wheelSurfaceSpeed, 0)
    local coreGasForcedFloorH = equivalentExternalTyreH_Wm2K * crownArea
        * clamp(finiteNumber(cfg.innerLinerExternalHMatchFraction, 1.00), 0, 1.25)
    local coreGasH = math.max(coreGasFlowH, coreGasForcedFloorH)
    local rimGasH = math.max(finiteNumber(cfg.rimNaturalConductanceWPerK, 5.5), 0)
        + math.max(finiteNumber(cfg.rimTurbulenceConductancePerSqrtMS, 1.65), 0) * turbulenceRoot
    local sidewallGasH = coreGasH
        * clamp(finiteNumber(static.sidewallAreaM2, 0.20)
            / math.max(finiteNumber(static.cavityFacingCrownAreaM2, 0.35), 0.01), 0.15, 2.5)
        * clamp(finiteNumber(cfg.sidewallGasAreaEffectiveness, 0.28), 0, 1.5)

    local wheelhouseAirspeed = math.max(finiteNumber(geom.safeAirspeed, geom.safeSpeed), 0)
        * clamp(finiteNumber(cfg.wheelhouseAirspeedFraction, 0.72), 0.15, 1.5)
    local hExternal = math.max(finiteNumber(cfg.rimStaticH_Wm2K, 8.0), 0)
        + math.max(finiteNumber(cfg.rimForcedHPerSqrtMS_Wm2K, 7.0), 0) * math.sqrt(wheelhouseAirspeed)
        + math.max(finiteNumber(cfg.rimRotationHPerSqrtMS_Wm2K, 2.0), 0) * math.sqrt(math.max(wheelSurfaceSpeed, 0))
    local rimAmbientH = hExternal * math.max(finiteNumber(static.rimAreaM2, 0.06), 0.02)
    local sidewallAmbientH = (7.0 + 4.0 * math.sqrt(wheelhouseAirspeed) + 0.42 * wheelhouseAirspeed)
        * math.max(finiteNumber(static.sidewallExternalAreaM2, static.sidewallAreaM2), 0.02)
        * clamp(finiteNumber(cfg.sidewallExternalAreaEffectiveness, 0.70), 0, 1.5)
    local brakeRimH = math.max(finiteNumber(cfg.brakeToRimConductanceWPerK, 1.05), 0)
        * math.max(TEMP_GAIN_RATE_CORE, 0)
    local beadRimH = math.max(finiteNumber(cfg.carcassBeadToRimConductanceWPerK, 1.35), 0)
    local coreSidewallH = math.max(finiteNumber(static.coreSidewallConductanceWPerK, 3.0), 0.1)

    local coreSideEachH = coreSidewallH * 0.5
    local gasSideEachH = sidewallGasH * 0.5
    local ambientSideEachH = sidewallAmbientH * 0.5
    local beadSideEachH = beadRimH * 0.5

    local sidewallOuterSourceW = math.max(finiteNumber(data.sidewall_outer_heat_pending_j, 0), 0) / math.max(stepDt, 1e-6)
    local sidewallInnerSourceW = math.max(finiteNumber(data.sidewall_inner_heat_pending_j, 0), 0) / math.max(stepDt, 1e-6)
    data.sidewall_outer_heat_pending_j = 0
    data.sidewall_inner_heat_pending_j = 0
    data.sidewall_heat_pending_j = 0
    local sidewallSourceW = sidewallOuterSourceW + sidewallInnerSourceW

    local coreCapacity = math.max(finiteNumber(static.crownCoreCapacityJPerK, geom.coreHeatCapacity), 1)
    local outerCapacity = math.max(finiteNumber(static.sidewallOuterCapacityJPerK, 700), 1)
    local innerCapacity = math.max(finiteNumber(static.sidewallInnerCapacityJPerK, 700), 1)
    local gasCapacity = math.max(finiteNumber(static.gasCapacityJPerK, 1), 1)
    local rimCapacity = math.max(finiteNumber(static.rimCapacityJPerK, 1), 1)

    sideOuterT=M._tread1D.applyEnergyJ(sideOuterT,outerCapacity,sidewallOuterSourceW*stepDt,ambient-15,M._physicalThermal.maxCoreTemp)
    sideInnerT=M._tread1D.applyEnergyJ(sideInnerT,innerCapacity,sidewallInnerSourceW*stepDt,ambient-10,M._physicalThermal.maxCoreTemp)

    local function pairExchange(aT,aC,bT,bC,g)
        local q=M._tread1D.exactRCExchangeJ(aT,aC,bT,bC,g,stepDt)
        return aT-q/aC,bT+q/bC,q
    end

    local qCoreGas; coreT,airT,qCoreGas=pairExchange(coreT,coreCapacity,airT,gasCapacity,coreGasH)
    local qCoreOuter; coreT,sideOuterT,qCoreOuter=pairExchange(coreT,coreCapacity,sideOuterT,outerCapacity,coreSideEachH)
    local qCoreInner; coreT,sideInnerT,qCoreInner=pairExchange(coreT,coreCapacity,sideInnerT,innerCapacity,coreSideEachH)
    local qOuterGas; sideOuterT,airT,qOuterGas=pairExchange(sideOuterT,outerCapacity,airT,gasCapacity,gasSideEachH)
    local qInnerGas; sideInnerT,airT,qInnerGas=pairExchange(sideInnerT,innerCapacity,airT,gasCapacity,gasSideEachH)
    local qRimGas; rimT,airT,qRimGas=pairExchange(rimT,rimCapacity,airT,gasCapacity,rimGasH)
    local qOuterRim; sideOuterT,rimT,qOuterRim=pairExchange(sideOuterT,outerCapacity,rimT,rimCapacity,beadSideEachH)
    local qInnerRim; sideInnerT,rimT,qInnerRim=pairExchange(sideInnerT,innerCapacity,rimT,rimCapacity,beadSideEachH)

    local qOuterAmbient=M._tread1D.exactBoundaryExchangeJ(sideOuterT,outerCapacity,ambient,ambientSideEachH,stepDt)
    sideOuterT=M._tread1D.applyEnergyJ(sideOuterT,outerCapacity,-qOuterAmbient,ambient-15,M._physicalThermal.maxCoreTemp)
    local qInnerAmbient=M._tread1D.exactBoundaryExchangeJ(sideInnerT,innerCapacity,ambient,ambientSideEachH,stepDt)
    sideInnerT=M._tread1D.applyEnergyJ(sideInnerT,innerCapacity,-qInnerAmbient,ambient-10,M._physicalThermal.maxCoreTemp)
    local qRimAmbient=M._tread1D.exactBoundaryExchangeJ(rimT,rimCapacity,ambient,rimAmbientH,stepDt)
    rimT=M._tread1D.applyEnergyJ(rimT,rimCapacity,-qRimAmbient,ambient-15,math.max(finiteNumber(cfg.maxRimTemp,220),ambient+1))
    local brakeBoundaryT=finiteNumber(brakeTemp,ambient)
    local qRimToBrake=M._tread1D.exactBoundaryExchangeJ(rimT,rimCapacity,brakeBoundaryT,brakeRimH,stepDt)
    rimT=M._tread1D.applyEnergyJ(rimT,rimCapacity,-qRimToBrake,ambient-15,math.max(finiteNumber(cfg.maxRimTemp,220),ambient+1))

    local coreToGasW=qCoreGas/stepDt
    local coreToOuterSidewallW=qCoreOuter/stepDt
    local coreToInnerSidewallW=qCoreInner/stepDt
    local outerSidewallToGasW=qOuterGas/stepDt
    local innerSidewallToGasW=qInnerGas/stepDt
    local rimToGasW=qRimGas/stepDt
    local outerSidewallBeadToRimW=qOuterRim/stepDt
    local innerSidewallBeadToRimW=qInnerRim/stepDt
    local outerSidewallExternalW=qOuterAmbient/stepDt
    local innerSidewallExternalW=qInnerAmbient/stepDt
    local rimExternalW=qRimAmbient/stepDt
    local brakeToRimW=-qRimToBrake/stepDt
    local sidewallBeadToRimW=outerSidewallBeadToRimW+innerSidewallBeadToRimW
    local coreToSidewallW=coreToOuterSidewallW+coreToInnerSidewallW
    local rimNetW=-rimToGasW+brakeToRimW+sidewallBeadToRimW-rimExternalW
    data.temp[4]=clamp(coreT,ambient-10,M._physicalThermal.maxCoreTemp)

    local previousAirTempC = finiteNumber(data.air_temp, ambient)
    data.sidewall_outer_temp = clamp(sideOuterT, ambient - 15, M._physicalThermal.maxCoreTemp)
    data.sidewall_inner_temp = clamp(sideInnerT, ambient - 10, M._physicalThermal.maxCoreTemp)
    data.air_temp = clamp(airT, ambient - 10,
        math.max(finiteNumber(M._physicalThermal.maxAirTemp, 180), ambient + 1))
    data.rim_temp = clamp(rimT, ambient - 15,
        math.max(finiteNumber(cfg.maxRimTemp, 220), ambient + 1))
    data.cavity_volume_l = static.cavityVolumeM3 * 1000
    data.cavity_sealed_air_mass_kg = static.sealedAirMassKg
    data.cavity_gas_capacity_j_k = static.gasCapacityJPerK
    data.sidewall_heat_capacity_j_k = static.sidewallTotalCapacityJPerK
    data.core_heat_capacity_j_k = static.crownCoreCapacityJPerK
    data.total_structural_heat_capacity_j_k = static.oldLumpedCoreCapacityJPerK
    data.rim_heat_capacity_j_k = static.rimCapacityJPerK
    data.rim_external_conductance_w_k = rimAmbientH
    data.core_cavity_conductance_w_k = coreGasH
    data.core_sidewall_conductance_w_k = coreSidewallH
    data.sidewall_air_conductance_w_k = sidewallGasH
    data.sidewall_external_conductance_w_k = sidewallAmbientH
    data.rim_air_conductance_w_k = rimGasH
    data.brake_to_rim_conductance_w_k = brakeRimH
    data.brake_to_rim_heat_w = brakeToRimW
    data.rim_to_cavity_heat_w = rimToGasW
    data.core_to_cavity_heat_w = coreToGasW
    data.core_to_sidewall_heat_w = coreToSidewallW
    data.core_to_sidewall_outer_heat_w = coreToOuterSidewallW
    data.core_to_sidewall_inner_heat_w = coreToInnerSidewallW
    data.sidewall_to_cavity_heat_w = outerSidewallToGasW + innerSidewallToGasW
    data.sidewall_outer_to_cavity_heat_w = outerSidewallToGasW
    data.sidewall_inner_to_cavity_heat_w = innerSidewallToGasW
    data.sidewall_external_cooling_w = outerSidewallExternalW + innerSidewallExternalW
    data.sidewall_outer_external_cooling_w = outerSidewallExternalW
    data.sidewall_inner_external_cooling_w = innerSidewallExternalW
    data.sidewall_bead_to_rim_heat_w = sidewallBeadToRimW
    data.sidewall_outer_bead_to_rim_heat_w = outerSidewallBeadToRimW
    data.sidewall_inner_bead_to_rim_heat_w = innerSidewallBeadToRimW
    data.sidewall_sel_source_w = sidewallSourceW
    data.sidewall_outer_source_w = sidewallOuterSourceW
    data.sidewall_inner_source_w = sidewallInnerSourceW
    data.sidewall_semantics_revision = 2
    data.cavity_peristaltic_flow_fraction = cavityFlowFraction
    data.cavity_peristaltic_air_speed_mps = cavityFlowSpeed
    data.cavity_deformation_pump_factor = deformationPump
    data.rim_airflow_mps = wheelhouseAirspeed

    ApplyThermalPressureDelta(wheelID, previousAirTempC, data.air_temp, "cavity-dT")
    UpdatePressureReadOnlyTelemetry(wheelID)
end

M._thermalGripCacheByWheel=M._thermalGripCacheByWheel or {}
M._tread1D.publishThermalGripCache=function(wheelID,data,physical,geom,thermalTick)
    if type(data)~="table" or type(physical)~="table" or type(geom)~="table" then return end
    local cache=M._thermalGripCacheByWheel[wheelID]
    local first=type(cache)~="table"
    cache=cache or {revision=0}
    local tick=math.max(math.floor(finiteNumber(thermalTick,data.thermal_master_tick or 0)),0)
    local profileKey=tostring(data.tyre_profile or "standard")
    if first or cache.profileKey~=profileKey or type(cache.profile)~="table" then
        local detected=getWheelTyreProfile(wheelID)
        cache.profile=detected and detected.profile or TYRE_PROFILES[profileKey] or TYRE_PROFILES.standard
        cache.profileKey=profileKey
        cache.profileId=tostring(cache.profile and cache.profile.id or profileKey)
        data.b100_slow_cache_dirty=true
    end
    cache.workingTemp=data.working_temp
    cache.physical=physical
    cache.surfaceTemp=data.surface_temp
    cache.treadField=data.tread_field
    cache.zoneGeometry=geom.zoneCellGeometry
    cache.flashTemp=finiteNumber(data.flash_temp,finiteNumber(cache.flashTemp,ENV_TEMP))
    cache.coreTemp=finiteNumber(data.temp and data.temp[4],finiteNumber(cache.coreTemp,ENV_TEMP))
    cache.gripDepthAvgTemp=finiteNumber(data.grip_depth_avg_temp,finiteNumber(cache.gripDepthAvgTemp,ENV_TEMP))

    local profile=cache.profile or TYRE_PROFILES.standard
    local macroGrip,macroRealistic,macroTemp=M._tread1D.evaluateDirectSurfaceGrip(
        data,profile,0,data.contact_zone_weights,false,cache)
    cache.macroCurveGrip=macroGrip
    cache.macroCurveGripRealistic=macroRealistic
    cache.macroGripDepthTemp=macroTemp

    local brushTable=M._flashMemory.brushCriticalSigmaYByProfile or {}
    local baseSigmaY=finiteNumber(brushTable[profile.id],M._flashMemory.brushCriticalSigmaYFallback)
    local bcache=M._pressureWheelBrush.slowCacheByWheel and M._pressureWheelBrush.slowCacheByWheel[wheelID] or nil
    if first or type(bcache)~="table" or tick%12==0 or data.b100_slow_cache_dirty==true then
        bcache=M._pressureWheelBrush.refreshSlowCache(wheelID,profile,baseSigmaY,macroGrip)
        data.b100_slow_cache_dirty=false
    else
        M._pressureWheelBrush.updateCachedThermalScale(wheelID,macroGrip)
    end
    cache.b100SlowCache=bcache
    cache.revision=math.max(math.floor(finiteNumber(cache.revision,0)),0)+1
    cache.publishedAtThermalTick=tick
    M._thermalGripCacheByWheel[wheelID]=cache
    data.thermal_cache_revision=cache.revision
    data.thermal_cache_age_ms=0
    data.thermal_cache_force_publish=false
    return cache
end

M._multiRateThermal=M._multiRateThermal or {masterHz=60,masterDt=1/60,maxCatchupTicks=12}
M._multiRateThermal.ensureState=function(data)
    data.multi_rate_thermal_state=type(data.multi_rate_thermal_state)=="table" and data.multi_rate_thermal_state or {}; local st=data.multi_rate_thermal_state
    if st._perfInitV~=1 then
        st.accumulatorS=math.max(finiteNumber(st.accumulatorS,0),0); st.sourceTimeS=math.max(finiteNumber(st.sourceTimeS,0),0); st.tick=math.max(math.floor(finiteNumber(st.tick,0)),0)
        st.pendingBulkJ=type(st.pendingBulkJ)=="table" and st.pendingBulkJ or {0,0,0}; st.pendingSurfaceJ=type(st.pendingSurfaceJ)=="table" and st.pendingSurfaceJ or {0,0,0}
        st.pendingCoreSourceJ=finiteNumber(st.pendingCoreSourceJ,0); st.pendingCoreApplyJ=finiteNumber(st.pendingCoreApplyJ,0); st.pendingFlashExcitationJ=finiteNumber(st.pendingFlashExcitationJ,0)
        st.pendingCellJ=type(st.pendingCellJ)=="table" and st.pendingCellJ or {{},{},{}}
        for z=1,3 do
            st.pendingBulkJ[z]=finiteNumber(st.pendingBulkJ[z],0); st.pendingSurfaceJ[z]=finiteNumber(st.pendingSurfaceJ[z],0)
            st.pendingCellJ[z]=type(st.pendingCellJ[z])=="table" and st.pendingCellJ[z] or {}
            for j=1,M._tread1D.cells do st.pendingCellJ[z][j]=finiteNumber(st.pendingCellJ[z][j],0) end
        end
        st.bulkWScratch=type(st.bulkWScratch)=="table" and st.bulkWScratch or {0,0,0}
        st.surfaceWScratch=type(st.surfaceWScratch)=="table" and st.surfaceWScratch or {0,0,0}
        st.sourceScratch=type(st.sourceScratch)=="table" and st.sourceScratch or {bulkJ={0,0,0},surfaceJ={0,0,0},coreJ=0,flashExcitationJ=0}
        st.diagScratch=type(st.diagScratch)=="table" and st.diagScratch or {}
        st._perfInitV=1
    end
    return st
end
M._multiRateThermal.accumulateSources=function(data,dt,bulkW,surfaceW,coreW,flashW,existingState)
    local st=existingState or M._multiRateThermal.ensureState(data); local step=math.max(finiteNumber(dt,0),0); if step<=0 then return st end; st.sourceTimeS=st.sourceTimeS+step
    for z=1,3 do st.pendingBulkJ[z]=st.pendingBulkJ[z]+finiteNumber(bulkW and bulkW[z],0)*step; st.pendingSurfaceJ[z]=st.pendingSurfaceJ[z]+finiteNumber(surfaceW and surfaceW[z],0)*step end; st.pendingCoreSourceJ=st.pendingCoreSourceJ+finiteNumber(coreW,0)*step; st.pendingFlashExcitationJ=st.pendingFlashExcitationJ+finiteNumber(flashW,0)*step; return st
end
M._multiRateThermal.consumeTickSources=function(st,tickDt)
    local out=st.sourceScratch; for z=1,3 do out.bulkJ[z]=0; out.surfaceJ[z]=0 end; out.coreJ=0; out.flashExcitationJ=0
    local available=math.max(finiteNumber(st.sourceTimeS,0),0); if available<=1e-12 then return out end
    local consume=math.min(math.max(finiteNumber(tickDt,0),0),available); local frac=clamp(consume/available,0,1)
    for z=1,3 do out.bulkJ[z]=st.pendingBulkJ[z]*frac; st.pendingBulkJ[z]=st.pendingBulkJ[z]-out.bulkJ[z]; out.surfaceJ[z]=st.pendingSurfaceJ[z]*frac; st.pendingSurfaceJ[z]=st.pendingSurfaceJ[z]-out.surfaceJ[z] end
    out.coreJ=st.pendingCoreSourceJ*frac; st.pendingCoreSourceJ=st.pendingCoreSourceJ-out.coreJ; out.flashExcitationJ=st.pendingFlashExcitationJ*frac; st.pendingFlashExcitationJ=st.pendingFlashExcitationJ-out.flashExcitationJ; st.sourceTimeS=math.max(available-consume,0); return out
end

M._multiRateThermal.runWheel=function(wheelID,data,physical,profile,geom,ctx,safeDt)
    local st=M._multiRateThermal.ensureState(data); local masterDt=1/math.max(finiteNumber(M._tread1D.thermalMasterHz,60),1); local bulkW=st.bulkWScratch; local surfaceW=st.surfaceWScratch
    for z=1,3 do bulkW[z]=finiteNumber(ctx.longitudinalTreadHeatW,0)*finiteNumber(ctx.contactWeights[z],1/3)+finiteNumber(ctx.rollingTreadHeatW,0)*finiteNumber(ctx.rollingZoneWeights[z],1/3)+finiteNumber(ctx.lateralTreadHeatW,0)*finiteNumber(ctx.flexWeights[z],1/3); surfaceW[z]=finiteNumber(ctx.bulkSlipHeatW,0)*finiteNumber(ctx.contactWeights[z],1/3) end
    M._multiRateThermal.accumulateSources(data,safeDt,bulkW,surfaceW,ctx.totalCoreHeatW,ctx.flashExcitationPowerW,st); st.accumulatorS=st.accumulatorS+safeDt; local processed=0; local diag=st.diagScratch
    diag.airW=0; diag.groundW=0; diag.radiationW=0; diag.coreTransferW=0; diag.roadRefreshRate=0; diag.grooveForcedCoolingW=0
    while st.accumulatorS+1e-12>=masterDt and processed<math.max(math.floor(finiteNumber(M._tread1D.thermalMaxCatchupTicks,12)),1) do
        st.accumulatorS=st.accumulatorS-masterDt; st.tick=st.tick+1; processed=processed+1; data.thermal_master_tick=st.tick; local src=M._multiRateThermal.consumeTickSources(st,masterDt)
        local circPending=M._circumferential.consumePendingBulkEnergy(data,geom.activeTreadCellsByZone)
        for z=1,3 do
            local zg=geom.zoneCellGeometry[z]; local n=zg.activeCount; local sourceWeightSum=0
            if zg.adaptive then
                local ref=math.max(zg.referenceCellThicknessM,1e-9)
                for j=1,n do sourceWeightSum=sourceWeightSum+finiteNumber(zg.thicknessM[j],ref)/ref end
            else
                sourceWeightSum=n
            end
            local invWeight=1/math.max(sourceWeightSum,1e-9); local ref=math.max(zg.referenceCellThicknessM,1e-9)
            for j=1,n do
                local w=zg.adaptive and finiteNumber(zg.thicknessM[j],ref)/ref or 1
                st.pendingCellJ[z][j]=finiteNumber(st.pendingCellJ[z][j],0)+src.bulkJ[z]*w*invWeight+finiteNumber(circPending[z] and circPending[z][j],0)
            end
            st.pendingCellJ[z][1]=st.pendingCellJ[z][1]+src.surfaceJ[z]
        end
        st.pendingCoreApplyJ=st.pendingCoreApplyJ+src.coreJ
        geom.circ.roadLocalFraction=clamp(finiteNumber(geom.circ.heatLocalFraction,0),0,1); geom.circ.roadBulkFraction=1-geom.circ.roadLocalFraction
        local roadCap=math.max(M._physicalThermal.roadPatchHeatCapacityPerM2*geom.contactPatchArea,M._physicalThermal.roadPatchMinCapacity)
        local initialRoadT=ctx.isWaterSurface and ENV_TEMP or finiteNumber(data.road_patch_temp,ctx.roadPatchTemp)
        local localGroundW,roadT=M._circumferential.depositLocalizedRoadBoundary(data,geom,ctx.totalGroundConductance,ctx.contactWeights,initialRoadT,masterDt,geom.circ.roadLocalFraction,roadCap)
        roadT=finiteNumber(roadT,initialRoadT)
        geom.circ.localBaseGroundCoolingW=finiteNumber(localGroundW,0); geom.circ.bulkBaseGroundCoolingW=0
        local circEx=M._circumferential.advanceThermal(data,geom,ctx.totalAirConductance,masterDt,st.tick); diag.airW=diag.airW+finiteNumber(circEx.airW,0); diag.radiationW=diag.radiationW+finiteNumber(circEx.radiationW,0); local totalGroundW=finiteNumber(localGroundW,0)
        for z=1,3 do
            local zg=geom.zoneCellGeometry[z]; local n=zg.activeCount; local field=data.tread_field[z]
            for j=1,n do local div=M._tread1D.getCellRateDivisor(j); if st.tick%div==0 then field[j]=M._tread1D.applyEnergyJ(field[j],zg.capacityJPerK[j],st.pendingCellJ[z][j],ENV_TEMP-10,M._tread1D.maxCellTemp); st.pendingCellJ[z][j]=0 end end
            for j=1,n-1 do local div=math.max(M._tread1D.getCellRateDivisor(j),M._tread1D.getCellRateDivisor(j+1)); if st.tick%div==0 then local distance=math.max(zg.centerM[j+1]-zg.centerM[j],1e-8); local fill=M._treadGrooveGeometry.getInterfaceRubberFillAtLiveDepth(physical,geom.nominalTreadDepth,zg.remainingDepthM,zg.endM[j]); local G=ctx.rubberK*zg.areaM2*fill/distance; local q=M._tread1D.exactRCExchangeJ(field[j],zg.capacityJPerK[j],field[j+1],zg.capacityJPerK[j+1],G,masterDt*div); field[j]=field[j]-q/zg.capacityJPerK[j]; field[j+1]=field[j+1]+q/zg.capacityJPerK[j+1]; data.thermal_internal_energy_sent_j=finiteNumber(data.thermal_internal_energy_sent_j,0)+q; data.thermal_internal_energy_received_j=finiteNumber(data.thermal_internal_energy_received_j,0)+q end end
            local surfaceT=finiteNumber(field[1],ENV_TEMP)
            local surfaceCap=math.max(finiteNumber(zg.capacityJPerK[1],0.1),0.1)
            local airG=math.max(finiteNumber(geom.baseAirConductanceEffective,0),0)/3
                + math.max(finiteNumber(geom.grooveForcedAirConductanceEffective,0),0)
                * math.max(finiteNumber(geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[z],1/3),0)
            local qAir=M._tread1D.exactBoundaryExchangeJ(surfaceT,surfaceCap,ENV_TEMP,airG,masterDt)
            field[1]=M._tread1D.applyEnergyJ(field[1],surfaceCap,-qAir,ENV_TEMP-10,M._tread1D.maxCellTemp)
            local zoneAirW=qAir/masterDt
            diag.grooveForcedCoolingW=diag.grooveForcedCoolingW
                + math.max(finiteNumber(geom.grooveForcedAirConductanceEffective,0),0)
                * math.max(finiteNumber(geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[z],1/3),0)
                * (surfaceT-ENV_TEMP)

            local zoneGroundG=ctx.totalGroundConductance
                * math.max(finiteNumber(geom.groundCoolingZoneShare and geom.groundCoolingZoneShare[z],ctx.contactWeights[z]),0)
                * finiteNumber(geom.circ.roadBulkFraction,1)
            local afterAirT=finiteNumber(field[1],surfaceT)
            local qGround=M._tread1D.exactRCExchangeJ(afterAirT,surfaceCap,roadT,roadCap,zoneGroundG,masterDt)
            field[1]=afterAirT-qGround/surfaceCap
            roadT=roadT+qGround/roadCap
            local zoneGroundW=qGround/masterDt
            geom.circ.bulkBaseGroundCoolingW=geom.circ.bulkBaseGroundCoolingW+zoneGroundW

            local beforeRadT=finiteNumber(field[1],afterAirT)
            local sk=math.max(beforeRadT+273.15,1); local ak=math.max(ENV_TEMP+273.15,1)
            local rawRadW=M._physicalThermal.emissivity*M._physicalThermal.stefanBoltzmann*(geom.exposedArea/6)*(sk^4-ak^4)
            local qRad=rawRadW*masterDt
            local equilibriumRadJ=surfaceCap*(beforeRadT-ENV_TEMP)
            if qRad*equilibriumRadJ>0 and math.abs(qRad)>math.abs(equilibriumRadJ) then qRad=equilibriumRadJ end
            field[1]=M._tread1D.applyEnergyJ(field[1],surfaceCap,-qRad,ENV_TEMP-10,M._tread1D.maxCellTemp)
            local zoneRadW=qRad/masterDt
            totalGroundW=totalGroundW+zoneGroundW; diag.airW=diag.airW+zoneAirW; diag.radiationW=diag.radiationW+zoneRadW
            data.surface_boundary_temp=type(data.surface_boundary_temp)=="table" and data.surface_boundary_temp or {}; local land=clamp(1-M._treadGrooveGeometry.getCurrentZoneSurfaceVoidRatio(physical,z,geom.nominalTreadDepth,zg.remainingDepthM),0.05,1); local halfR=(0.5*zg.thicknessM[1])/math.max(ctx.rubberK*zg.areaM2*land,1e-6); local boundaryNetW=finiteNumber(src.surfaceJ[z],0)/masterDt-zoneAirW-zoneGroundW-zoneRadW; local coldest=math.min(finiteNumber(ENV_TEMP,20),roadT,finiteNumber(field[1],ENV_TEMP)); local candidate=clamp(field[1]+boundaryNetW*halfR,coldest,M._tread1D.maxCellTemp+120); local prev=finiteNumber(data.surface_boundary_temp[z],field[1]); local tau=candidate>=prev and math.max(finiteNumber(M._tread1D.surfaceBoundaryRiseTauS,0.025),0.001) or math.max(finiteNumber(M._tread1D.surfaceBoundaryFallTauS,0.080),0.001); data.surface_boundary_temp[z]=clamp(prev+(candidate-prev)*(1-math.exp(-masterDt/tau)),coldest,M._tread1D.maxCellTemp+120)
        end
        if ctx.isWaterSurface then roadT=ENV_TEMP else roadT=roadT+(ROAD_TEMP-roadT)*(1-math.exp(-masterDt/math.max(M._physicalThermal.roadPatchStaticRecoveryTau,0.001))); local passes=(geom.safeSpeed*masterDt)/math.max(geom.footprintLength*M._physicalThermal.roadRefreshLengthFactor,0.001); local alpha=1-math.exp(-math.max(passes,0)); roadT=roadT+(ROAD_TEMP-roadT)*alpha; diag.roadRefreshRate=alpha/masterDt; roadT=clamp(roadT,ROAD_TEMP-20,250) end; data.road_patch_temp=roadT; diag.groundW=diag.groundW+totalGroundW
        local avgSurface=TempRingsToAvgTemp(data.surface_temp or data.temp,ctx.loadBias,ctx.contactWeights); local flashInputW=src.flashExcitationJ/masterDt; local flashToSurfaceRaw=M._physicalThermal.flashToSurfaceConductance*math.max(finiteNumber(data.flash_temp,avgSurface)-avgSurface,0); local flashToSurface=clamp(flashToSurfaceRaw,0,math.max(ctx.slipHeatW*M._physicalThermal.flashMaxRetainedTyreShare,0)); local flashRoad=M._physicalThermal.flashEffectiveRoadConductance*math.max(finiteNumber(data.flash_temp,avgSurface)-roadT,0); data.flash_temp=clamp(finiteNumber(data.flash_temp,avgSurface)+(flashInputW-flashToSurface-flashRoad)/ctx.flashHeatCapacity*masterDt,avgSurface,M._physicalThermal.maxFlashTemp); data.flash_to_surface_w=flashToSurface; data.flash_road_loss_w=flashRoad
        if st.tick%12==0 then
            data.temp[4]=M._tread1D.applyEnergyJ(data.temp[4],geom.coreHeatCapacity,st.pendingCoreApplyJ,ENV_TEMP-10,M._physicalThermal.maxCoreTemp); st.pendingCoreApplyJ=0
            for z=1,3 do local zg=geom.zoneCellGeometry[z]; local n=zg.activeCount; local field=data.tread_field[z]; local q=M._tread1D.exactRCExchangeJ(data.temp[4],geom.coreHeatCapacity,field[n],zg.capacityJPerK[n],ctx.baseSkinCoreConductance/3,masterDt*12); data.temp[4]=data.temp[4]-q/geom.coreHeatCapacity; field[n]=field[n]+q/zg.capacityJPerK[n]; diag.coreTransferW=diag.coreTransferW+q/(masterDt*12) end
            M._updateWheelCavityThermals(data,wheelID,geom,ctx.brakeTemp,masterDt*12)
        end
        M._tread1D.deriveTemps(data,physical); M._tread1D.publishThermalGripCache(wheelID,data,physical,geom,st.tick)
    end
    data.thermal_master_hz=60; data.thermal_tier_surface_hz=60; data.thermal_tier_cells_2_3_hz=30; data.thermal_tier_cells_4_6_hz=15; data.thermal_tier_cells_7_10_hz=7.5; data.thermal_tier_cells_11_12_hz=5; data.thermal_core_hz=5; data.thermal_pending_core_j=finiteNumber(st.pendingCoreSourceJ,0)+finiteNumber(st.pendingCoreApplyJ,0); data.thermal_pending_tread_j=0
    data.adaptive_tread_cells_enabled=M._tread1D.adaptiveCellRetirementEnabled~=false
    data.adaptive_start_depth_mm=M._tread1D.getAdaptiveStartDepthM(physical)*1000
    data.adaptive_reference_cell_mm=M._tread1D.getAdaptiveReferenceCellThicknessM(physical)*1000
    data.active_cells_outer=geom.activeTreadCellsByZone[1]; data.active_cells_middle=geom.activeTreadCellsByZone[2]; data.active_cells_inner=geom.activeTreadCellsByZone[3]
    data.surface_partial_cell_mm_outer=finiteNumber(geom.zoneCellGeometry[1].surfacePartialThicknessM,0)*1000
    data.surface_partial_cell_mm_middle=finiteNumber(geom.zoneCellGeometry[2].surfacePartialThicknessM,0)*1000
    data.surface_partial_cell_mm_inner=finiteNumber(geom.zoneCellGeometry[3].surfacePartialThicknessM,0)*1000
    local rateSig=tostring(geom.activeTreadCellsByZone[1])..":"..tostring(geom.activeTreadCellsByZone[2])..":"..tostring(geom.activeTreadCellsByZone[3])
    if type(data.current_cell_rate_hz)~="table" or data._current_cell_rate_signature~=rateSig then
        data.current_cell_rate_hz={{},{},{}}
        for z=1,3 do
            for j=1,geom.zoneCellGeometry[z].activeCount do data.current_cell_rate_hz[z][j]=60/M._tread1D.getCellRateDivisor(j) end
        end
        data._current_cell_rate_signature=rateSig
    end
    if processed>0 then
        data.thermal_pending_tread_j=0
        for z=1,3 do for j=1,M._tread1D.cells do data.thermal_pending_tread_j=data.thermal_pending_tread_j+math.abs(finiteNumber(st.pendingCellJ[z][j],0)) end end
    end
    data.thermal_internal_balance_error_j=finiteNumber(data.thermal_internal_energy_received_j,0)-finiteNumber(data.thermal_internal_energy_sent_j,0)
    data.thermal_cache_age_ms=math.max(finiteNumber(st.accumulatorS,0),0)*1000
    if processed>0 then
        st.lastDiagAverage={
            airW=diag.airW/processed, groundW=diag.groundW/processed,
            radiationW=diag.radiationW/processed, coreTransferW=diag.coreTransferW/processed,
            roadRefreshRate=diag.roadRefreshRate,
            grooveForcedCoolingW=diag.grooveForcedCoolingW/processed
        }
        return diag,processed
    end
    if type(st.lastDiagAverage)=="table" then return st.lastDiagAverage,1 end
    return diag,1
end

M._wearResearch.prepareWearPacket = function(wheelID, data, physical, profile, geom,
        contactWeights, loadBias, thermalBrushUtilization, slidingFraction, elapsedDt,
        isWaterSurface, isGrassSurface, predictedFlashTempC)
    data._wearModelScratch=type(data._wearModelScratch)=="table" and data._wearModelScratch or {}
    local wearModel=data._wearModelScratch
    wearModel.cfg=M._wearResearch
    wearModel.slidingFraction=clamp(finiteNumber(slidingFraction,0),0,1)
    wearModel.localSlipFactor=wearModel.slidingFraction>0 and 1.0 or 0.0
    wearModel.localSlipSpeed=wearModel.slidingFraction>0 and finiteNumber(geom.safeSlipSpeed,0) or 0
    wearModel.abrasionSlidingScale=wearModel.slidingFraction>0 and 1.0 or 0.0
    wearModel.circumferenceM=math.max(2*math.pi*finiteNumber(geom.safeRadius,0.33),0.05)
    wearModel.contactDuty=clamp(finiteNumber(geom.footprintLength,0)/wearModel.circumferenceM,0,
        finiteNumber(wearModel.cfg.contactDutyMax,0.20))
    wearModel.settingScale=math.max(WEAR_RATE,0)
        *math.max(finiteNumber(wearModel.cfg.regenVisualTestMultiplier,1.0),0)
    wearModel.k1=finiteNumber(wearModel.cfg.baseRoadK1,0.040)
        *M._wearResearch.getProfileScale(profile)
        *M._slickCompounds.getWearMultiplier(profile)
        *wearModel.settingScale
    wearModel.k2=finiteNumber(wearModel.cfg.velocitySlopeK2,0.37)
    wearModel.surfaceScale=geom.rallyDirtCfg
        and finiteNumber(geom.rallyDirtCfg.heightWearScale,1.0)
        or (isWaterSurface and finiteNumber(wearModel.cfg.waterWearMultiplier,0.35)
            or (isGrassSurface and finiteNumber(wearModel.cfg.grassWearMultiplier,0.12) or 1.0))
    wearModel.frictionWorkState=M._wearResearch.getFrictionWorkWearState(wheelID,geom,wearModel.slidingFraction)
    wearModel.frictionWorkAuthority=clamp(finiteNumber(wearModel.frictionWorkState.authority,1.0),0,2.0)

    wearModel.zoneDepthM=type(wearModel.zoneDepthM)=="table" and wearModel.zoneDepthM or {0,0,0}
    wearModel.zoneTempMult=type(wearModel.zoneTempMult)=="table" and wearModel.zoneTempMult or {1,1,1}
    wearModel.zoneMacroTempMult=type(wearModel.zoneMacroTempMult)=="table" and wearModel.zoneMacroTempMult or {1,1,1}
    wearModel.zoneFlashTempC=type(wearModel.zoneFlashTempC)=="table" and wearModel.zoneFlashTempC or {0,0,0}
    wearModel.zoneFlashInternalFactor=type(wearModel.zoneFlashInternalFactor)=="table" and wearModel.zoneFlashInternalFactor or {1,1,1}
    wearModel.zoneFlashEquivalentExtra=type(wearModel.zoneFlashEquivalentExtra)=="table" and wearModel.zoneFlashEquivalentExtra or {0,0,0}
    wearModel.zoneFlashExtraDepthM=type(wearModel.zoneFlashExtraDepthM)=="table" and wearModel.zoneFlashExtraDepthM or {0,0,0}
    wearModel.zoneFlashFastDepthM=type(wearModel.zoneFlashFastDepthM)=="table" and wearModel.zoneFlashFastDepthM or {0,0,0}
    wearModel.zoneMacroDepthM=type(wearModel.zoneMacroDepthM)=="table" and wearModel.zoneMacroDepthM or {0,0,0}
    wearModel.zonePressureMPa=type(wearModel.zonePressureMPa)=="table" and wearModel.zonePressureMPa or {0,0,0}
    wearModel.zoneEffectiveTempC=type(wearModel.zoneEffectiveTempC)=="table" and wearModel.zoneEffectiveTempC or {0,0,0}
    wearModel.zoneSurfaceTempC=type(wearModel.zoneSurfaceTempC)=="table" and wearModel.zoneSurfaceTempC or {0,0,0}
    wearModel.zoneCell1TempC=type(wearModel.zoneCell1TempC)=="table" and wearModel.zoneCell1TempC or {0,0,0}
    wearModel.zoneCell2TempC=type(wearModel.zoneCell2TempC)=="table" and wearModel.zoneCell2TempC or {0,0,0}
    wearModel.zoneTempWeights=type(wearModel.zoneTempWeights)=="table" and wearModel.zoneTempWeights or {{0,0,0},{0,0,0},{0,0,0}}
    wearModel.zoneSurfaceAuthority=type(wearModel.zoneSurfaceAuthority)=="table" and wearModel.zoneSurfaceAuthority or {0,0,0}
    wearModel.zoneDestructionActivation=type(wearModel.zoneDestructionActivation)=="table" and wearModel.zoneDestructionActivation or {0,0,0}
    wearModel.zoneRemovedMassKg=type(wearModel.zoneRemovedMassKg)=="table" and wearModel.zoneRemovedMassKg or {0,0,0}
    wearModel.zoneActivatedDestroyedMassKg=type(wearModel.zoneActivatedDestroyedMassKg)=="table" and wearModel.zoneActivatedDestroyedMassKg or {0,0,0}

    for zone=1,3 do
        wearModel.zoneDepthM[zone]=0; wearModel.zoneTempMult[zone]=1; wearModel.zoneMacroTempMult[zone]=1
        wearModel.zoneFlashTempC[zone]=0; wearModel.zoneFlashInternalFactor[zone]=1; wearModel.zoneFlashEquivalentExtra[zone]=0
        wearModel.zoneFlashExtraDepthM[zone]=0; wearModel.zoneFlashFastDepthM[zone]=0; wearModel.zoneMacroDepthM[zone]=0; wearModel.zonePressureMPa[zone]=0
        wearModel.zoneEffectiveTempC[zone]=0; wearModel.zoneSurfaceTempC[zone]=0; wearModel.zoneCell1TempC[zone]=0; wearModel.zoneCell2TempC[zone]=0
        wearModel.zoneSurfaceAuthority[zone]=0; wearModel.zoneDestructionActivation[zone]=0; wearModel.zoneRemovedMassKg[zone]=0; wearModel.zoneActivatedDestroyedMassKg[zone]=0
        wearModel.zoneTempWeights[zone]=type(wearModel.zoneTempWeights[zone])=="table" and wearModel.zoneTempWeights[zone] or {0,0,0}
        wearModel.zoneTempWeights[zone][1],wearModel.zoneTempWeights[zone][2],wearModel.zoneTempWeights[zone][3]=0,0,0
    end

    wearModel.meanSurfaceAuthority=0; wearModel.meanEffectiveTempC=0; wearModel.meanTempMult=0; wearModel.meanMacroTempMult=0
    wearModel.meanFlashTempC=0; wearModel.meanFlashInternalFactor=0; wearModel.meanFlashEquivalentExtra=0
    wearModel.meanFlashExtraDepthStepM=0; wearModel.meanMacroDepthStepM=0; wearModel.meanPressureMPa=0; wearModel.meanDepthStepM=0
    wearModel.meanDestructionActivation=0; wearModel.removedMassKgStep=0; wearModel.activatedDestroyedMassKgStep=0
    wearModel.flashDamageKneeC=nil; wearModel.flashAblationKneeC=nil
    wearModel.flashMicroHotAreaFraction=clamp(finiteNumber(wearModel.cfg.flashMicroHotAreaFraction,0),0,0.15)

    wearModel._macroContactSurfaceC=finiteNumber(data.circumferential_contact_surface_temp_c,
        TempRingsToAvgTemp(data.surface_temp or data.temp,loadBias,contactWeights))
    wearModel.predictedFlashTempC=math.max(finiteNumber(predictedFlashTempC,
        finiteNumber(data.flash_temp,wearModel._macroContactSurfaceC)),wearModel._macroContactSurfaceC)
    wearModel._flashRiseC=math.max(wearModel.predictedFlashTempC-wearModel._macroContactSurfaceC,0)

    local areaPerZone=math.max(finiteNumber(geom.treadArea,0.15)/3,1e-6)
    local rho=math.max(finiteNumber(geom.rubberDensity,
        finiteNumber(physical.rubberDensity,M._physicalThermal.rubberDensity)),100)
    local nominalDepth=math.max(finiteNumber(geom.nominalTreadDepth,finiteNumber(physical.treadDepthM,0.006)),0.001)
    if wearModel.slidingFraction>0 and wearModel.localSlipSpeed>1e-5 and elapsedDt>0 then
        for zone=1,3 do
            local zoneWeight=clamp(finiteNumber(contactWeights[zone],1/3),0,1)
            local zonePressurePa=finiteNumber(geom.safeLoad,0)*zoneWeight*3/math.max(finiteNumber(geom.contactPatchArea,0),1e-5)
            local zoneWearTempC,zoneWearSurfaceC,zoneWearCell1C,zoneWearCell2C,
                zoneWearSurfaceW,zoneWearCell1W,zoneWearCell2W,zoneWearSurfaceAuthority=
                M._wearResearch.getEffectiveWearTemperature(data,zone,profile,thermalBrushUtilization)
            local zoneTempMult=geom.rallyDirtCfg
                and M._rallyDirt.getWearTemperatureMultiplier(zoneWearTempC,data.rally_surface_class)
                or M._wearResearch.getTemperatureMultiplier(zoneWearTempC,profile)
            wearModel.zoneMacroTempMult[zone]=zoneTempMult

            wearModel.zoneFlashTempC[zone]=clamp(zoneWearSurfaceC+wearModel._flashRiseC,
                zoneWearSurfaceC,finiteNumber(M._physicalThermal.maxFlashTemp,650))
            wearModel.zoneFlashInternalFactor[zone],wearModel.flashDamageKneeC,wearModel.flashAblationKneeC=
                M._wearResearch.getFlashDestructiveInternalFactor(wearModel.zoneFlashTempC[zone],profile)
            wearModel.zoneFlashEquivalentExtra[zone]=0

            local pressureRatio=zonePressurePa/math.max(finiteNumber(wearModel.cfg.referencePressurePa,1000000),1)
            local speedRatio=wearModel.localSlipSpeed/math.max(finiteNumber(wearModel.cfg.referenceSlidingSpeedMps,1.0),0.01)
            local localWearKgM3=wearModel.k1*pressureRatio*(1+wearModel.k2*speedRatio)
            local depthRateMps=localWearKgM3/rho*wearModel.localSlipSpeed*wearModel.slidingFraction
                *wearModel.abrasionSlidingScale*wearModel.contactDuty*wearModel.surfaceScale
                *wearModel.frictionWorkAuthority
            wearModel.zoneMacroDepthM[zone]=math.max(depthRateMps*zoneTempMult*elapsedDt,0)
            wearModel.zoneFlashExtraDepthM[zone]=0
            wearModel.zoneDepthM[zone]=wearModel.zoneMacroDepthM[zone]
            wearModel.zoneFlashFastDepthM[zone]=(wearModel.flashAblationKneeC
                and wearModel.zoneFlashTempC[zone]>=wearModel.flashAblationKneeC)
                and wearModel.zoneMacroDepthM[zone] or 0

            local destructionActivation=0
            if wearModel.flashDamageKneeC and wearModel.flashAblationKneeC
                and wearModel.flashAblationKneeC>wearModel.flashDamageKneeC then
                local x=clamp((wearModel.zoneFlashTempC[zone]-wearModel.flashDamageKneeC)
                    /(wearModel.flashAblationKneeC-wearModel.flashDamageKneeC),0,1)
                destructionActivation=x*x*(3-2*x)
            end
            wearModel.zoneDestructionActivation[zone]=destructionActivation

            wearModel.zoneTempMult[zone]=zoneTempMult; wearModel.zonePressureMPa[zone]=zonePressurePa/1000000
            wearModel.zoneEffectiveTempC[zone]=zoneWearTempC; wearModel.zoneSurfaceTempC[zone]=zoneWearSurfaceC
            wearModel.zoneCell1TempC[zone]=zoneWearCell1C; wearModel.zoneCell2TempC[zone]=zoneWearCell2C
            wearModel.zoneTempWeights[zone][1]=zoneWearSurfaceW; wearModel.zoneTempWeights[zone][2]=zoneWearCell1W; wearModel.zoneTempWeights[zone][3]=zoneWearCell2W
            wearModel.zoneSurfaceAuthority[zone]=zoneWearSurfaceAuthority
            wearModel.meanSurfaceAuthority=wearModel.meanSurfaceAuthority+zoneWearSurfaceAuthority*zoneWeight
            wearModel.meanEffectiveTempC=wearModel.meanEffectiveTempC+zoneWearTempC*zoneWeight
            wearModel.meanTempMult=wearModel.meanTempMult+zoneTempMult*zoneWeight
            wearModel.meanMacroTempMult=wearModel.meanMacroTempMult+zoneTempMult*zoneWeight
            wearModel.meanFlashTempC=wearModel.meanFlashTempC+wearModel.zoneFlashTempC[zone]*zoneWeight
            wearModel.meanFlashInternalFactor=wearModel.meanFlashInternalFactor+wearModel.zoneFlashInternalFactor[zone]*zoneWeight
            wearModel.meanFlashEquivalentExtra=wearModel.meanFlashEquivalentExtra+wearModel.zoneFlashEquivalentExtra[zone]*zoneWeight
            wearModel.meanFlashExtraDepthStepM=wearModel.meanFlashExtraDepthStepM+wearModel.zoneFlashExtraDepthM[zone]/3
            wearModel.meanMacroDepthStepM=wearModel.meanMacroDepthStepM+wearModel.zoneMacroDepthM[zone]/3
            wearModel.meanPressureMPa=wearModel.meanPressureMPa+zonePressurePa/1000000*zoneWeight
            wearModel.meanDepthStepM=wearModel.meanDepthStepM+wearModel.zoneDepthM[zone]/3
            wearModel.meanDestructionActivation=wearModel.meanDestructionActivation+destructionActivation*zoneWeight
        end
    end

    if geom.rallyDirtCfg then
        M._rallyDirt.applyDirectionalEdgeWear(data,wheelID,wearModel.zoneDepthM,
            geom.nominalTreadDepth,data.rally_surface_class)
    end

    local reserveDepth=getNonWearableTreadReserveM(nominalDepth)
    for zone=1,3 do
        local remainingDepth=clamp(finiteNumber(data.tread_remaining_depth_m
            and data.tread_remaining_depth_m[zone],nominalDepth),reserveDepth,nominalDepth)
        local removedDepth=math.min(math.max(finiteNumber(wearModel.zoneDepthM[zone],0),0),
            math.max(remainingDepth-reserveDepth,0))
        local fill=removedDepth>0 and M._treadGrooveGeometry.getRubberFillFractionOverLiveDepth(
            physical,nominalDepth,remainingDepth,0,removedDepth) or 1
        local removedMass=removedDepth*areaPerZone*rho*fill
        local activatedMass=removedMass*clamp(finiteNumber(wearModel.zoneDestructionActivation[zone],0),0,1)
        wearModel.zoneRemovedMassKg[zone]=removedMass
        wearModel.zoneActivatedDestroyedMassKg[zone]=activatedMass
        wearModel.removedMassKgStep=wearModel.removedMassKgStep+removedMass
        wearModel.activatedDestroyedMassKgStep=wearModel.activatedDestroyedMassKgStep+activatedMass
    end

    local deCfg=type(wearModel.cfg.destructionEnergy)=="table" and wearModel.cfg.destructionEnergy or {}
    wearModel.destructionEnthalpyJPerKg=math.max(finiteNumber(deCfg.enthalpyJPerKg,200000),0)
    wearModel.destructionEnergyDemandJ=(deCfg.enabled==false) and 0
        or wearModel.activatedDestroyedMassKgStep*wearModel.destructionEnthalpyJPerKg
    return wearModel
end

M._wearResearch.predictDestructiveFlash = function(data, geom, loadBias, contactWeights,
        interfaceMuForHeat, effectiveLocalSlipSpeed, thermalSlidingLoadFraction,
        effectiveSlipHeatTune, slipLocalization, grossSlipHeatW)
    local surfaceC=TempRingsToAvgTemp(data.surface_temp,loadBias,contactWeights)
    local excitationW=interfaceMuForHeat*geom.safeLoad*effectiveLocalSlipSpeed
        *math.sqrt(clamp(thermalSlidingLoadFraction,0,1))*effectiveSlipHeatTune*slipLocalization
        *M._physicalThermal.flashInputFraction
    excitationW=excitationW/(1+excitationW/math.max(M._physicalThermal.flashInputSaturationW,1))
    local conductance=math.max(M._physicalThermal.flashToSurfaceConductance
        +M._physicalThermal.flashEffectiveRoadConductance,0.1)
    local capacity=math.max(conductance*M._physicalThermal.flashHeatTau,0.05)
    local currentC=math.max(finiteNumber(data.flash_temp,surfaceC),surfaceC)
    local toSurfaceW=clamp(M._physicalThermal.flashToSurfaceConductance
        *math.max(currentC-surfaceC,0),0,
        math.max(grossSlipHeatW*M._physicalThermal.flashMaxRetainedTyreShare,0))
    local roadW=M._physicalThermal.flashEffectiveRoadConductance
        *math.max(currentC-finiteNumber(data.road_patch_temp,ROAD_TEMP),0)
    local predictDt=1/math.max(finiteNumber(M._tread1D.thermalMasterHz,60),1)
    local predictedC=clamp(currentC+(excitationW-toSurfaceW-roadW)/capacity*predictDt,
        surfaceC,finiteNumber(M._physicalThermal.maxFlashTemp,650))
    return surfaceC,excitationW,capacity,predictedC
end

local function CalcTyreWear(dt, wheelID, groundModel, loadBias, treadCoef, slipEnergy,
                            load, angularVel, brakeTemp, tyreWidth, airspeed, deformationEnergy, g_table, wheel_name,
                            loadRaw, pressurePa, groundSpeed, longitudinalSpeed, wheelRadius, combinedSlipSpeed,
                            longitudinalSlipSpeed, lateralSlipSpeed, isGrassSurface, isWaterSurface)
    local rawDt = math.max(finiteNumber(dt, 0), 0)
    local safeDt = clamp(rawDt, 0, 0.05)
    local conservedDt = rawDt
    local thermalSourceDt = conservedDt
    local detectedTyre = getWheelTyreProfile(wheelID)
    local profile = detectedTyre.profile
    local physical = M._physicalThermal.getPhysicalProfile(profile)
    local material = M._physicalThermal.getEffectiveTreadMaterial(profile)
    local default_working_temp = WORKING_TEMP >= 0 and WORKING_TEMP or profile.workingTemp
    local _, configuredGaugePressurePa, configuredPressureSource = GetConfiguredPressureReferencePa(wheelID)

    if not syncEnvironmentTemperatureFromVehicle() then
        syncEnvironmentTemperatureFromMailbox()
    end
    local starting_temp = ENV_TEMP
    local defaultWheelData = {
        working_temp = default_working_temp,
        temp = { starting_temp, starting_temp, starting_temp, starting_temp },
        surface_temp = { starting_temp, starting_temp, starting_temp },
        surface_boundary_temp = { starting_temp, starting_temp, starting_temp },
        tread_bulk_temp = { starting_temp, starting_temp, starting_temp },
        flash_temp = starting_temp,
        road_patch_temp = ROAD_TEMP,
        condition = 100,
        lastTyregrip = 1,
        brakeCooling = RT.baseBrakeCoolings[wheelID],
        tyre_profile = profile.id,
        tyre_profile_class = profile.classId or profile.id,
        tyre_profile_label = profile.label,
        tyre_name = detectedTyre.displayName,
        tyre_internal_name = detectedTyre.internalName,
        tyre_profile_source = detectedTyre.source,
        profile_working_temp = profile.workingTemp,
        profile_overheat_start = profile.overheatStart,
        air_temp = starting_temp,
        sidewall_outer_temp = starting_temp,
        sidewall_inner_temp = starting_temp,
        sidewall_semantics_revision = 2,
        sidewall_outer_heat_pending_j = 0,
        sidewall_inner_heat_pending_j = 0,
        rim_temp = starting_temp,
        pressure_psi = configuredGaugePressurePa / PSI_TO_PA,
        thermal_pressure_delta_psi = 0,
        thermal_pressure_ratio = 1,
        thermal_pressure_last_applied_temp_c = starting_temp,
        thermal_pressure_cumulative_delta_pa = 0,
        thermal_pressure_pending_delta_pa = 0,
        thermal_pressure_last_configured_gauge_pa = configuredGaugePressurePa,
        pressure_source = "initial-config-fallback",
        pressure_reference_psi = configuredGaugePressurePa / PSI_TO_PA,
        pressure_reference_source = configuredPressureSource,
        pressure_reference_temp_c = ENV_TEMP,
        pressure_update_hz = 1 / math.max(finiteNumber(M._physicalThermal.wheelCavity.thermalUpdateIntervalS, 0.20), 0.05),
        pressure_control_state = "beamng-native-read-only",
    }

    local brake_coolingSetting
    if string.lower(string.sub(wheel_name, 1, 1)) == "f" then
        brake_coolingSetting = RT.brakeDuctSettings[1]
    else
        brake_coolingSetting = RT.brakeDuctSettings[2]
    end
    wheelCache[wheelID].brakeCooling = (((brake_coolingSetting or 13) - 1) / 12) * (RT.baseBrakeCoolings[wheelID] or 0.5)

    local data = tyreData[wheelID] or defaultWheelData
    data.working_temp = default_working_temp
    data.tyre_profile = profile.id
    data.tyre_profile_class = profile.classId or profile.id
    data.tyre_profile_label = profile.label
    data.tyre_name = detectedTyre.displayName
    data.tyre_internal_name = detectedTyre.internalName
    data.tyre_profile_source = detectedTyre.source
    data.profile_working_temp = profile.workingTemp
    data.profile_overheat_start = profile.overheatStart
    data.rally_surface_class = wheelCache[wheelID] and wheelCache[wheelID].rallySurfaceClass
        or data.rally_surface_class or "road"
    data.rally_surface_model = M._rallyDirt.surfaces[data.rally_surface_class]
        and M._rallyDirt.modelVersion or "road-model-owned-curve"
    data.rally_surface_router_source = data.rally_surface_router_source or "gfx-contact-pair"
    data.rally_road_model_active = M._rallyDirt.isRallyProfile(profile)
        and data.rally_surface_class == "road"
    data.rally_dirt_model_active = M._rallyDirt.isRallyProfile(profile)
        and M._rallyDirt.surfaces[data.rally_surface_class] ~= nil
    data.surface_temp = type(data.surface_temp) == "table" and data.surface_temp or {
        finiteNumber(data.temp[1], ENV_TEMP), finiteNumber(data.temp[2], ENV_TEMP), finiteNumber(data.temp[3], ENV_TEMP)
    }
    for surfaceZone = 1, 3 do
        data.surface_temp[surfaceZone] = finiteNumber(data.surface_temp[surfaceZone], data.temp[surfaceZone] or ENV_TEMP)
    end
    data.flash_temp = finiteNumber(data.flash_temp, TempRingsToAvgTemp(data.surface_temp, loadBias))
    data.road_patch_temp = finiteNumber(data.road_patch_temp, ROAD_TEMP)

    if M._careerWearPersistence and M._careerWearPersistence.applyWheelIfPending then
        M._careerWearPersistence.applyWheelIfPending(wheelID, data, profile, physical)
    end

    if (wheelPreheatRevision[wheelID] or 0) < preheatRevision then
        applyPreheatToWheel(wheelID, data, preheatRevision)
        data.flash_temp = TempRingsToAvgTemp(data.surface_temp or data.temp, loadBias)
    end

    local geom = BuildTyreThermalGeometry(data, physical, material, tyreWidth, wheelRadius, loadRaw,
        pressurePa, groundSpeed, airspeed, combinedSlipSpeed, longitudinalSlipSpeed,
        lateralSlipSpeed, groundModel, loadBias)
    local circAngularVelocity = wheelCache[wheelID] and wheelCache[wheelID].angularVelocity or angularVel
    geom.circ = M._circumferential.beginStep(data, circAngularVelocity, conservedDt, geom)
    geom.rallyDirtCfg = data.rally_dirt_model_active
        and M._rallyDirt.surfaces[data.rally_surface_class] or nil
    local cavityStatic = M._ensureWheelCavityStatic(data, wheelID, geom)
    if cavityStatic then
        geom.coreHeatCapacity = math.max(finiteNumber(cavityStatic.crownCoreCapacityJPerK, geom.coreHeatCapacity), 1)
        geom.oldLumpedCoreHeatCapacity = finiteNumber(cavityStatic.oldLumpedCoreCapacityJPerK, geom.coreHeatCapacity)
        geom.sidewallHeatCapacity = finiteNumber(cavityStatic.sidewallTotalCapacityJPerK, 0)
        geom.treadCoolingWidth = finiteNumber(cavityStatic.treadCoolingWidthM, geom.safeWidth)
        geom.treadCoolingWidthFactor = finiteNumber(cavityStatic.treadCoolingWidthFactor, 1.0)
        geom.treadCoolingArea = math.max(2 * math.pi * geom.safeRadius * geom.treadCoolingWidth, geom.treadArea)
        geom.exposedArea = math.max(geom.treadCoolingArea - geom.contactPatchArea, 0.01)
        geom.sectionHeightM = finiteNumber(cavityStatic.sidewallHeightM, 0)
        geom.sectionAspectRatio = finiteNumber(cavityStatic.sidewallAspectRatio, 0)
        geom.sidewallExternalArea = finiteNumber(cavityStatic.sidewallExternalAreaM2, cavityStatic.sidewallAreaM2)
    end

    local brushLoadPrev = finiteNumber(data.brush_vertical_load_n, geom.safeLoad)
    local brushLoadTau = math.max(finiteNumber(M._pressureWheelBrush.dynamicLoadFilterTauS, 0.045), 0.005)
    local brushLoadAlpha = safeDt > 0 and (1 - math.exp(-safeDt / brushLoadTau)) or 1
    data.brush_vertical_load_n = math.max(brushLoadPrev + (geom.safeLoad - brushLoadPrev) * brushLoadAlpha, 0)

    local slipTune = math.max(TEMP_SLIP_GAIN_RATE, 0)
    local cornerTune = math.max(TEMP_WORK_GAIN_RATE, 0)
    local effectiveSlipHeatTune = isGrassSurface and math.max(GRASS_SLIP_HEAT_RATE, 0) or slipTune
    effectiveSlipHeatTune = effectiveSlipHeatTune
        * finiteNumber(geom.rallyDirtCfg and geom.rallyDirtCfg.slipHeatScale, 1.0)

    local wearDepthHeatScale = M._tread1D.getWearDepthHeatScales(data, physical)

    local crrEff = physical.rollingResistanceCoeff
        * (geom.loadRatio ^ 0.12)
        * (1 + 0.0018 * math.max(geom.safeSpeed - 25, 0))
        * (geom.pressureFactor ^ 0.70)
    local rollingMechanicalLossW = crrEff * geom.safeLoad * geom.safeSpeed
        * finiteNumber(wearDepthHeatScale.rolling, 1.0)
    local rollingHeatW = rollingMechanicalLossW
        * clamp(finiteNumber(M._tread1D.rollingTyreRetainedFraction, 0.90), 0, 1)

    local longitudinalDeformationHeatW = 0
    local lateralDeformationHeatW = 0
    local deformationHeatW = 0

    local thermalSurfaceSpeed = math.max(math.abs(finiteNumber(
        wheelCache[wheelID] and wheelCache[wheelID].angularVelocity, 0)) * geom.safeRadius,
        M._flashMemory.brushMinSurfaceSpeedMps)
    local thermalCurveGrip
    if geom.rallyDirtCfg then
        thermalCurveGrip = select(1,
            M._rallyDirt.getTemperatureGrip(data, data.rally_surface_class))
    else
        thermalCurveGrip = select(1, M._tread1D.evaluateDirectSurfaceGrip(
            data, profile, loadBias, data.contact_zone_weights, false))
    end
    local thermalCriticalMuScale = clamp(thermalCurveGrip, 0.05, 1.0)
    local thermalCriticalScale = clamp(thermalCriticalMuScale, M._flashMemory.brushCriticalThermalScaleMin, 1.0)
    local thermalCriticalX = math.max(M._flashMemory.brushCriticalSigmaX * thermalCriticalScale, 0.001)
    local thermalBrushTable = M._flashMemory.brushCriticalSigmaYByProfile
    local thermalBaseCriticalY = finiteNumber(
        thermalBrushTable[profile.id], M._flashMemory.brushCriticalSigmaYFallback)
    local thermalCriticalY, thermalStructure = GetPressureWheelBrushCriticalSigmaY(
        wheelID, profile, thermalBaseCriticalY, thermalCriticalMuScale, data.brush_vertical_load_n or geom.safeLoad)

    -- Research-backed transverse contact / flex map. Pressure/load/structure
    -- decides shoulder-vs-centre normal pressure; lateral carcass compliance decides
    -- an additional shoulder-biased hysteresis map. Both conserve total wheel load.
    local lateralSigmaForZones = geom.safeLateralSlip / thermalSurfaceSpeed
    local livePressurePsiForZones = geom.safePressure / PSI_TO_PA
    local referencePressurePsiForZones = finiteNumber(thermalStructure and thermalStructure.referencePressurePsi, nil)
        or select(1, getTyreStructuralReferencePressurePsi(wheelID, profile))
        or (finiteNumber(configuredGaugePressurePa, OPTIMAL_PRESSURE) / PSI_TO_PA)
        or finiteNumber(data.pressure_reference_psi, 30.0)
    local referencePressureSourceForZones = thermalStructure and thermalStructure.referencePressureSource or "profile-fallback"
    local contactWeights, flexWeights, crossTreadState = CalcResearchCrossTreadWeights(
        profile.id, loadBias, geom.loadRatio, livePressurePsiForZones, referencePressurePsiForZones,
        thermalStructure and thermalStructure.stiffnessFactor or 1.0,
        lateralSigmaForZones, thermalBaseCriticalY)
    geom.weights = contactWeights
    M._treadGrooveGeometry.updateCoolingZoneShares(data, physical, geom, contactWeights)
    local rollingZoneWeights = {}
    local rollingZoneBias = {
        math.max(finiteNumber(M._tread1D.rollingShoulderZoneBias, 1.25), 0),
        math.max(finiteNumber(M._tread1D.rollingCentreZoneBias, 0.70), 0),
        math.max(finiteNumber(M._tread1D.rollingShoulderZoneBias, 1.25), 0)
    }
    local rollingWeightSum = 0
    for zone = 1, 3 do
        rollingZoneWeights[zone] = math.max(finiteNumber(contactWeights[zone], 1 / 3), 0)
            * rollingZoneBias[zone]
        rollingWeightSum = rollingWeightSum + rollingZoneWeights[zone]
    end
    if rollingWeightSum <= 1e-9 then
        rollingZoneWeights = {0.390625, 0.21875, 0.390625}
    else
        for zone = 1, 3 do rollingZoneWeights[zone] = rollingZoneWeights[zone] / rollingWeightSum end
    end

    local thermalNormX = (geom.safeLongitudinalSlip / thermalSurfaceSpeed) / thermalCriticalX
    local thermalNormY = (geom.safeLateralSlip / thermalSurfaceSpeed) / thermalCriticalY
    local thermalBrushUtilization = math.sqrt(thermalNormX * thermalNormX + thermalNormY * thermalNormY)
    local thermalSlidingLengthFraction = clamp(thermalBrushUtilization, 0, 1)
    local thermalSlidingLoadFraction = clamp(
        thermalSlidingLengthFraction * thermalSlidingLengthFraction * (3 - 2 * thermalSlidingLengthFraction), 0, 1)

    -- Research-backed gross-slip dissipation. The exact slip-loss power is
    -- the tangential force/slip-velocity dot product (Fx*Vsx + Fy*Vsy). BeamNG does
    -- not expose the full per-wheel contact-force vector here, so use the reduced
    -- magnitude approximation |Ft|*|v_slip| with |Ft| ~= mu_eff*Fz, then weight by B.
    -- Use the reconstructed CURRENT sliding/Stribeck friction level
    -- instead of assuming the full static road coefficient during a slide.  This
    -- is especially important for launch wheelspin, where heating must follow the
    -- lower sliding-friction state once BeamNG has moved away from static friction.
    local heatFrictionState = M._physicalThermal.estimateInterfaceFrictionState(
        wheelID, groundModel, geom.safeSlipSpeed)
    local interfaceMuForHeat = clamp(finiteNumber(heatFrictionState.effectiveMu, geom.groundMu), 0.01, 6.0)

    local longitudinalFialaUtilization = clamp(math.abs(thermalNormX), 0, 1)
    local lateralFialaUtilization = clamp(math.abs(thermalNormY), 0, 1)
    local longitudinalFialaForceFraction = 1 - ((1 - longitudinalFialaUtilization) ^ 3)
    local lateralFialaForceFraction = 1 - ((1 - lateralFialaUtilization) ^ 3)
    local combinedForceFractionNorm = math.sqrt(
        longitudinalFialaForceFraction * longitudinalFialaForceFraction
        + lateralFialaForceFraction * lateralFialaForceFraction)
    local combinedForceScale = combinedForceFractionNorm > 1
        and (1 / combinedForceFractionNorm) or 1
    local longitudinalFialaForceEstimateN = interfaceMuForHeat * geom.safeLoad
        * longitudinalFialaForceFraction * combinedForceScale
    local lateralFialaForceEstimateN = interfaceMuForHeat * geom.safeLoad
        * lateralFialaForceFraction * combinedForceScale

    geom.legacyHeatForceLongitudinalN = longitudinalFialaForceEstimateN
    geom.legacyHeatForceLateralN = lateralFialaForceEstimateN

    local longitudinalMechanicalSlipPowerW = longitudinalFialaForceEstimateN
        * math.abs(geom.safeLongitudinalSlip)
    local lateralMechanicalSlipPowerW = lateralFialaForceEstimateN
        * math.abs(geom.safeLateralSlip)
    local totalBrushMechanicalPowerW = longitudinalMechanicalSlipPowerW + lateralMechanicalSlipPowerW

    geom.nativeSlipPower = M._physicalThermal.getNativeSlipPower(
        wheelID, wheelCache[wheelID], geom.safeLongitudinalSlip, geom.safeLateralSlip)
    local nativeSlipPowerValid = geom.nativeSlipPower ~= nil
    local nativeSlipPowerW = nativeSlipPowerValid and math.max(finiteNumber(geom.nativeSlipPower.powerW, 0), 0) or 0
    local nativeLongitudinalSlipPowerW = nativeSlipPowerValid
        and math.max(finiteNumber(geom.nativeSlipPower.longitudinalPowerW, 0), 0) or 0
    local nativeLateralSlipPowerW = nativeSlipPowerValid
        and math.max(finiteNumber(geom.nativeSlipPower.lateralPowerW, 0), 0) or 0

    if nativeSlipPowerValid and nativeSlipPowerW > 0
        and (nativeLongitudinalSlipPowerW + nativeLateralSlipPowerW) <= 1e-9 then
        local legacyDirectionalTotalW = longitudinalMechanicalSlipPowerW + lateralMechanicalSlipPowerW
        if legacyDirectionalTotalW > 1e-9 then
            nativeLongitudinalSlipPowerW = nativeSlipPowerW * longitudinalMechanicalSlipPowerW / legacyDirectionalTotalW
            nativeLateralSlipPowerW = nativeSlipPowerW - nativeLongitudinalSlipPowerW
        else
            nativeLongitudinalSlipPowerW = nativeSlipPowerW
            nativeLateralSlipPowerW = 0
        end
    end

    local localSlidingVelocityFactor = thermalSlidingLoadFraction > 0 and 1.0 or 0.0
    local trueSlidingFraction = thermalSlidingLoadFraction
    local adhesionDeformationFraction = 1 - thermalSlidingLoadFraction
    local effectiveLocalSlipSpeed = thermalSlidingLoadFraction > 0 and geom.safeSlipSpeed or 0
    local thermalDissipationFraction = thermalSlidingLoadFraction

    local extraFlexBaseFraction = clamp(
        finiteNumber(M._tread1D.extraFlexHysteresisFraction, 0.08)
        * physical.deformationScale
        * cornerTune
        * finiteNumber(geom.rallyDirtCfg and geom.rallyDirtCfg.flexHeatScale, 1.0),
        0, 0.50)
    local lateralComplianceGain = clamp(
        finiteNumber(crossTreadState and crossTreadState.hysteresisComplianceGain, 1.0), 0.40, 2.00)
    longitudinalDeformationHeatW = longitudinalMechanicalSlipPowerW
        * adhesionDeformationFraction * extraFlexBaseFraction
        * finiteNumber(wearDepthHeatScale.longitudinal, 1.0)
    lateralDeformationHeatW = lateralMechanicalSlipPowerW
        * adhesionDeformationFraction * extraFlexBaseFraction * lateralComplianceGain
        * finiteNumber(wearDepthHeatScale.lateral, 1.0)
    deformationHeatW = longitudinalDeformationHeatW + lateralDeformationHeatW

    local longitudinalSlidingMechanicalW
    local lateralSlidingMechanicalW
    if nativeSlipPowerValid then
        longitudinalSlidingMechanicalW = nativeLongitudinalSlipPowerW * effectiveSlipHeatTune
        lateralSlidingMechanicalW = nativeLateralSlipPowerW * cornerTune
    else
        longitudinalSlidingMechanicalW = longitudinalMechanicalSlipPowerW
            * trueSlidingFraction * effectiveSlipHeatTune
        lateralSlidingMechanicalW = lateralMechanicalSlipPowerW
            * trueSlidingFraction * cornerTune
    end
    local slidingMechanicalPowerW = longitudinalSlidingMechanicalW + lateralSlidingMechanicalW
    local grossSlipHeatW = slidingMechanicalPowerW * physical.slipHeatPartition

    local longitudinalTreadShare = clamp(
        finiteNumber(M._tread1D.longitudinalDeformationTreadShare, 0.45), 0, 1)
    local longitudinalSidewallShare = clamp(
        finiteNumber(M._tread1D.longitudinalDeformationSidewallShare, 0.45), 0, 1 - longitudinalTreadShare)
    local longitudinalCoreShare = math.max(1 - longitudinalTreadShare - longitudinalSidewallShare, 0)
    local lateralTreadShare = clamp(
        finiteNumber(M._tread1D.lateralDeformationTreadShare, 0.45), 0, 1)
    local lateralSidewallShare = clamp(
        finiteNumber(M._tread1D.lateralDeformationSidewallShare, 0.50), 0, 1 - lateralTreadShare)
    local lateralCoreShare = math.max(1 - lateralTreadShare - lateralSidewallShare, 0)

    local longitudinalTreadHeatW = longitudinalDeformationHeatW * longitudinalTreadShare
    local lateralTreadHeatW = lateralDeformationHeatW * lateralTreadShare
    local longitudinalSidewallHeatW = longitudinalDeformationHeatW * longitudinalSidewallShare
    local lateralSidewallHeatW = lateralDeformationHeatW * lateralSidewallShare
    local longitudinalCoreHeatW = longitudinalDeformationHeatW * longitudinalCoreShare
    local lateralCoreHeatW = lateralDeformationHeatW * lateralCoreShare
    local rollingTreadHeatW = rollingHeatW * M._tread1D.treadRollingHeatShare
    geom.sidewallRollingHeatShare = M._getSidewallRollingHeatShare(data, geom)
    geom.sidewallRollingHeatW = rollingHeatW * geom.sidewallRollingHeatShare
    geom.rollingCoreHeatW = math.max(rollingHeatW - rollingTreadHeatW
        - geom.sidewallRollingHeatW, 0)
    geom.sidewallOuterHeatShare, geom.sidewallInnerHeatShare,
        geom.sidewallFlexSplitProxy, geom.sidewallFlexSplitExponent =
        M._getActualSidewallHeatSplit(rollingZoneWeights, flexWeights, crossTreadState)
    geom.sidewallOuterRollingHeatW = geom.sidewallRollingHeatW * geom.sidewallOuterHeatShare
    geom.sidewallInnerRollingHeatW = geom.sidewallRollingHeatW * geom.sidewallInnerHeatShare

    local shoulderRollingSum = math.max(rollingZoneWeights[1] + rollingZoneWeights[3], 1e-9)
    local longitudinalOuterSidewallShare = clamp(rollingZoneWeights[1] / shoulderRollingSum, 0.03, 0.97)
    local lateralOuterSidewallShare = clamp(geom.sidewallOuterHeatShare, 0.03, 0.97)
    geom.sidewallLongitudinalFlexHeatW = longitudinalSidewallHeatW
    geom.sidewallLateralFlexHeatW = lateralSidewallHeatW
    geom.sidewallOuterFlexHeatW = longitudinalSidewallHeatW * longitudinalOuterSidewallShare
        + lateralSidewallHeatW * lateralOuterSidewallShare
    geom.sidewallInnerFlexHeatW = longitudinalSidewallHeatW * (1 - longitudinalOuterSidewallShare)
        + lateralSidewallHeatW * (1 - lateralOuterSidewallShare)

    data.sidewall_outer_heat_pending_j = math.max(finiteNumber(data.sidewall_outer_heat_pending_j, 0), 0)
        + (geom.sidewallOuterRollingHeatW + geom.sidewallOuterFlexHeatW) * thermalSourceDt
    data.sidewall_inner_heat_pending_j = math.max(finiteNumber(data.sidewall_inner_heat_pending_j, 0), 0)
        + (geom.sidewallInnerRollingHeatW + geom.sidewallInnerFlexHeatW) * thermalSourceDt
    data.sidewall_heat_pending_j = 0
    local treadDistributedHeatW = longitudinalTreadHeatW + lateralTreadHeatW + rollingTreadHeatW
    local totalCoreHeatW = longitudinalCoreHeatW + lateralCoreHeatW + geom.rollingCoreHeatW

    -- Persson-style finite slip-distance localization is retained only for the
    -- microscopic flash state. Research ref: [R4]. The 1-D field itself receives conserved retained
    -- friction heat at its physical surface boundary.
    local thermalResidenceTimeS = geom.footprintLength / math.max(thermalSurfaceSpeed, M._flashMemory.minRefreshSpeedMps)
    local thermalSlipDistancePerPassM = effectiveLocalSlipSpeed * thermalResidenceTimeS
    local localizationLengthM = math.max(M._physicalThermal.surfaceSlipLocalizationLengthM, 0.0001)
    local slipLocalization = 1 - math.exp(-thermalSlipDistancePerPassM / localizationLengthM)
    local surfaceLocalizationFactor = slipLocalization

    local avgSurfaceBefore,flashExcitationPowerW,flashHeatCapacity,predictedFlashTempC =
        M._wearResearch.predictDestructiveFlash(data,geom,loadBias,contactWeights,
            interfaceMuForHeat,effectiveLocalSlipSpeed,thermalSlidingLoadFraction,
            effectiveSlipHeatTune,slipLocalization,grossSlipHeatW)

    local wearModel = M._wearResearch.prepareWearPacket(wheelID, data, physical, profile, geom,
        contactWeights, loadBias, thermalBrushUtilization, thermalSlidingLoadFraction, conservedDt,
        isWaterSurface, isGrassSurface, predictedFlashTempC)
    wearModel.destructionEnergyDemandW=thermalSourceDt>0
        and math.max(finiteNumber(wearModel.destructionEnergyDemandJ,0),0)/thermalSourceDt or 0
    wearModel.destructionEnergyCapW=grossSlipHeatW*clamp(finiteNumber(
        M._wearResearch.destructionEnergy.maxGrossRetainedFraction,1.0),0,1)
    wearModel.destructionEnergySinkW=math.min(wearModel.destructionEnergyDemandW,wearModel.destructionEnergyCapW)
    local slipHeatW=math.max(grossSlipHeatW-wearModel.destructionEnergySinkW,0)
    wearModel.survivingRetainedFraction=grossSlipHeatW>1e-9 and slipHeatW/grossSlipHeatW or 1.0

    local rawInterfaceSlipPowerW = totalBrushMechanicalPowerW
    local rawSlipHeatW = grossSlipHeatW
    local legacyCombinedSlipHeatW = longitudinalSlidingMechanicalW * physical.slipHeatPartition * wearModel.survivingRetainedFraction
    local lateralResearchHeatW = lateralSlidingMechanicalW * physical.slipHeatPartition * wearModel.survivingRetainedFraction
    local hotAcceptance = 1.0

    local staticAirTune = math.max(TEMP_COOL_RATE, 0)
    local speedAirTune = math.max(TEMP_COOL_VEL_RATE, 0)
    local hAir = 7.0 * staticAirTune
        + (4.0 * math.sqrt(geom.safeAirspeed) + 0.42 * geom.safeAirspeed) * speedAirTune

    geom.grooveForcedAirSpeedMps = math.min(
        math.max(geom.safeAirspeed, thermalSurfaceSpeed),
        geom.grooveForcedConvectionSpeedCapMps)
    geom.grooveForcedH_Wm2K = geom.grooveWallArea > 0 and (
        (4.0 * math.sqrt(math.max(geom.grooveForcedAirSpeedMps, 0))
            + 0.42 * math.max(geom.grooveForcedAirSpeedMps, 0))
        * speedAirTune * geom.grooveAirflowEffectiveness) or 0
    geom.grooveForcedAirConductance = geom.grooveForcedH_Wm2K * geom.grooveWallArea
    geom.grooveForcedCoolingW = 0
    geom.baseAirConductanceEffective = hAir * geom.exposedArea
    geom.grooveForcedAirConductanceEffective = geom.grooveForcedAirConductance
    local totalAirConductance = geom.baseAirConductanceEffective + geom.grooveForcedAirConductanceEffective

    local groundTune = isGrassSurface and math.max(GRASS_GROUND_COOLING_SCALE, 0)
        or math.max(GROUND_COOLING_SCALE, 0)
    local hGround = 2100 * (1 + 0.035 * math.sqrt(geom.safeSpeed)) * groundTune
    local rawGroundConductanceSolid = hGround * geom.contactPatchArea * geom.groundContactFactor
    local grooveGroundContactScale = isGrassSurface and 1.0
        or clamp(finiteNumber(geom.roadGroundConductanceScale, 1.0), 0.05, 1.0)
    local rawGroundConductance = rawGroundConductanceSolid * grooveGroundContactScale
    local totalGroundConductance = rawGroundConductance
        * M._physicalThermal.thinSurfaceRoadConductanceScale
    local waterCoolingMultiplier = isWaterSurface and WATER_COOLING_MULTIPLIER or 1
    geom.baseAirConductanceEffective = geom.baseAirConductanceEffective * waterCoolingMultiplier
    geom.grooveForcedAirConductanceEffective = geom.grooveForcedAirConductanceEffective * waterCoolingMultiplier
    totalAirConductance = geom.baseAirConductanceEffective + geom.grooveForcedAirConductanceEffective
    totalGroundConductance = totalGroundConductance * waterCoolingMultiplier

    local roadPatchTemp = isWaterSurface and ENV_TEMP or finiteNumber(data.road_patch_temp, ROAD_TEMP)

    geom.circ.localHeatW = slipHeatW * clamp(finiteNumber(geom.circ.heatLocalFraction, 0), 0, 1)
    geom.circ.bulkHeatW = math.max(slipHeatW - geom.circ.localHeatW, 0)
    M._circumferential.depositHeat(data, geom.circ.localHeatW * thermalSourceDt, contactWeights)

    geom.circ.roadLocalFraction = clamp(finiteNumber(geom.circ.heatLocalFraction, 0), 0, 1)
    geom.circ.roadBulkFraction = 1 - geom.circ.roadLocalFraction
    geom.circ.localBaseGroundCoolingW = 0
    geom.circ.bulkBaseGroundCoolingW = 0
    geom.circ.exchange = nil
    geom.circ.pendingBulkCellW = nil

    local totalGroundTempDelta = 0
    local totalSkinAirCoolingW = 0
    local totalGroundCoolingW = 0
    local totalSlidingCoolingW = 0
    local totalRadiationW = 0
    local totalDegradationW = 0
    local totalSkinCoreTransferW = 0

    local flashToSurfaceRawW = M._physicalThermal.flashToSurfaceConductance
        * math.max(finiteNumber(data.flash_temp, avgSurfaceBefore) - avgSurfaceBefore, 0)
    local flashToSurfaceCapW = slipHeatW * M._physicalThermal.flashMaxRetainedTyreShare
    local flashToSurfaceW = clamp(flashToSurfaceRawW, 0, math.max(flashToSurfaceCapW, 0))

    local rubberK=math.max(finiteNumber(geom.rubberConductivity,M._physicalThermal.rubberConductivity),0.02); local baseSkinCoreConductance=physical.skinCoreConductance*(geom.treadArea/M._physicalThermal.referenceTreadArea)
    local thermalCtx=type(data._thermalCtxScratch)=="table" and data._thermalCtxScratch or {}; data._thermalCtxScratch=thermalCtx
    thermalCtx.longitudinalTreadHeatW=longitudinalTreadHeatW; thermalCtx.lateralTreadHeatW=lateralTreadHeatW; thermalCtx.rollingTreadHeatW=rollingTreadHeatW
    thermalCtx.contactWeights=contactWeights; thermalCtx.rollingZoneWeights=rollingZoneWeights; thermalCtx.flexWeights=flexWeights; thermalCtx.bulkSlipHeatW=geom.circ.bulkHeatW
    thermalCtx.totalCoreHeatW=totalCoreHeatW; thermalCtx.flashExcitationPowerW=flashExcitationPowerW; thermalCtx.totalAirConductance=totalAirConductance; thermalCtx.totalGroundConductance=totalGroundConductance
    thermalCtx.roadPatchTemp=roadPatchTemp; thermalCtx.isWaterSurface=isWaterSurface; thermalCtx.rubberK=rubberK; thermalCtx.baseSkinCoreConductance=baseSkinCoreConductance
    thermalCtx.slipHeatW=slipHeatW; thermalCtx.flashHeatCapacity=flashHeatCapacity; thermalCtx.brakeTemp=brakeTemp; thermalCtx.loadBias=loadBias
    local thermalDiag,thermalTicks=M._multiRateThermal.runWheel(wheelID,data,physical,profile,geom,thermalCtx,thermalSourceDt)
    totalSkinAirCoolingW=finiteNumber(thermalDiag and thermalDiag.airW,0)/math.max(thermalTicks,1); totalGroundCoolingW=finiteNumber(thermalDiag and thermalDiag.groundW,0)/math.max(thermalTicks,1); totalRadiationW=finiteNumber(thermalDiag and thermalDiag.radiationW,0)/math.max(thermalTicks,1); totalSkinCoreTransferW=finiteNumber(thermalDiag and thermalDiag.coreTransferW,0)/math.max(thermalTicks,1); geom.grooveForcedCoolingW=finiteNumber(thermalDiag and thermalDiag.grooveForcedCoolingW,0)/math.max(thermalTicks,1); roadPatchTemp=finiteNumber(data.road_patch_temp,roadPatchTemp)
    local roadRefreshRate=finiteNumber(thermalDiag and thermalDiag.roadRefreshRate,0); flashToSurfaceW=finiteNumber(data.flash_to_surface_w,flashToSurfaceW); local flashRoadLossW=finiteNumber(data.flash_road_loss_w,0)
    M._circumferential.refreshContactThermal(data,geom,loadBias,contactWeights,M._thermalGripCacheByWheel[wheelID]); local avgSurfaceAfter=TempRingsToAvgTemp(data.surface_temp,loadBias,contactWeights)
    if M._repeatedTestThermalCap.enabled then local workingCap=math.max(finiteNumber(data.working_temp,profile.workingTemp),ENV_TEMP-10); local treadCap=math.max(workingCap*M._repeatedTestThermalCap.bulkTreadMaxWorkingFactor,ENV_TEMP-10); for z=1,3 do local field=data.tread_field[z]; local free=clamp(math.floor(finiteNumber(M._tread1D.uncappedRoadSideCells,3)),0,#field); for j=free+1,#field do field[j]=math.min(finiteNumber(field[j],workingCap),treadCap) end end; data.temp[4]=math.min(finiteNumber(data.temp[4],workingCap),workingCap); M._tread1D.deriveTemps(data,physical) end

    local avgSkinAfter = TempRingsToAvgTemp(data.temp, loadBias, contactWeights)
    local avgBulkAfter = TempRingsToAvgTemp(data.tread_bulk_temp or data.temp, loadBias, contactWeights)

    data.pressure_psi = math.max(finiteNumber(geom.actualPressure, geom.safePressure), 0) / PSI_TO_PA
    data.contact_patch_m2 = geom.contactPatchArea
    data.contact_patch_ratio = geom.contactPatchRatio
    -- contact-patch provenance/debug telemetry. These expose the raw
    -- carcass+pneumatic request and the large-deformation saturation separately.
    data.contact_patch_raw_m2 = finiteNumber(geom.contactPatchRawArea, geom.contactPatchArea)
    data.contact_patch_max_m2 = finiteNumber(geom.contactPatchMaxArea, geom.contactPatchArea)
    data.contact_patch_saturation_ratio = finiteNumber(geom.contactPatchSaturationRatio, 1.0)
    data.contact_effective_mean_pressure_pa = finiteNumber(geom.contactEffectivePressurePa, 0)
    data.contact_carcass_equivalent_pressure_pa = finiteNumber(geom.contactCarcassPressurePa, 0)
    data.contact_carcass_sidewall_scale = finiteNumber(geom.contactCarcassSidewallScale, 1.0)
    data.contact_carcass_aspect_ratio = finiteNumber(geom.contactCarcassAspectRatio, 0.50)
    data.contact_patch_model = "carcass-pressure+geometric-saturation[CP-R1/R2;CP-E1/E2]"
    data.contact_patch_length_m = geom.footprintLength
    data.road_patch_temp = roadPatchTemp
    data.road_refresh_rate_hz = roadRefreshRate
    data.tyre_width_m = geom.safeWidth
    data.tyre_radius_m = geom.safeRadius
    data.ground_contact_factor = geom.groundContactFactor
    data.ground_cooling_delta = totalGroundTempDelta
    data.circumferential_road_cooling_local_fraction = finiteNumber(geom.circ.roadLocalFraction, 0)
    data.circumferential_road_cooling_bulk_fraction = finiteNumber(geom.circ.roadBulkFraction, 1)
    data.road_cooling_local_base_w = finiteNumber(geom.circ.localBaseGroundCoolingW, 0)
    data.road_cooling_bulk_base_w = finiteNumber(geom.circ.bulkBaseGroundCoolingW, 0)
    data.road_cooling_local_feature_exchange_w = 0
    data.road_cooling_total_w = finiteNumber(totalGroundCoolingW, 0)
    data.distance_last_step = geom.safeSpeed * conservedDt
    data.is_grass_surface = isGrassSurface == true
    data.is_water_surface = isWaterSurface == true
    data.water_cooling_multiplier = waterCoolingMultiplier
    data.surface_slip_heat_rate = effectiveSlipHeatTune
    data.surface_ground_cooling_percent = groundTune * 100
    data.rally_dirt_slip_heat_scale = finiteNumber(
        geom.rallyDirtCfg and geom.rallyDirtCfg.slipHeatScale, 1.0)
    data.rally_dirt_flex_heat_scale = finiteNumber(
        geom.rallyDirtCfg and geom.rallyDirtCfg.flexHeatScale, 1.0)
    data.slip_speed_mps = geom.safeSlipSpeed
    data.tread_area_m2 = geom.treadArea
    data.exposed_area_m2 = geom.exposedArea
    data.tread_cooling_area_m2 = finiteNumber(geom.treadCoolingArea, geom.exposedArea)
    data.tread_air_exposed_area_m2 = geom.exposedArea
    data.tread_cooling_width_m = geom.treadCoolingWidth
    data.tread_cooling_width_factor = geom.treadCoolingWidthFactor
    data.tyre_section_height_m = geom.sectionHeightM
    data.tyre_section_aspect_ratio = geom.sectionAspectRatio
    data.thermal_geometry_source = cavityStatic and cavityStatic.geometrySource or "runtime-fallback"
    data.sidewall_external_area_m2 = geom.sidewallExternalArea
    data.tread_void_ratio = geom.treadVoidRatio
    data.tread_surface_void_ratio_fresh = geom.treadVoidRatio
    data.tread_surface_void_ratio_live = geom.currentSurfaceVoidRatio
    data.tread_surface_land_fraction_live = geom.surfaceLandFraction
    data.groove_ground_contact_pressure_exponent = geom.roadGroundContactPressureExponent
    data.groove_ground_contact_conductance_scale = geom.roadGroundConductanceScale
    data.ground_conductance_solid_reference_w_k = rawGroundConductanceSolid
    data.ground_conductance_groove_adjusted_w_k = rawGroundConductance
    data.tread_groove_floor_void_ratio = geom.grooveFloorVoidRatio
    data.tread_volume_void_ratio_live = geom.volumeVoidRatio
    data.tread_rubber_fill_fraction = geom.rubberFillFraction
    data.tread_full_mass_kg = geom.fullTreadMass
    data.tread_effective_mass_kg = geom.treadMass
    data.tread_thermal_mass_reduction_fraction = 1 - geom.rubberFillFraction
    data.tread_fresh_groove_depth_m = geom.freshGrooveDepthM
    data.tread_post_groove_wearable_m = geom.postGrooveWearableM
    data.tread_structural_reserve_m = geom.structuralReserveM
    data.tread_groove_geometry_closure_error_m = geom.grooveGeometryClosureErrorM
    data.tread_active_groove_depth_m = geom.activeGrooveDepthM
    data.tread_current_groove_opening_width_m = geom.currentGrooveOpeningWidthM
    data.tread_groove_taper_half_angle_deg = geom.grooveTaperHalfAngleDeg
    data.core_reference_tread_depth_m = geom.coreReferenceTreadDepthM
    data.core_explicit_tread_migration_depth_m = geom.explicitTreadMigrationDepthM
    data.core_migrated_to_tread_capacity_j_k = geom.coreMigratedToTreadCapacityJPerK
    data.groove_active_depth_m = geom.activeGrooveDepthM
    data.groove_depth_fraction = geom.grooveDepthFraction
    data.groove_wall_area_m2 = geom.grooveWallArea
    data.cooling_zone_surface_void_outer = geom.zoneSurfaceVoidRatio and geom.zoneSurfaceVoidRatio[1] or geom.currentSurfaceVoidRatio
    data.cooling_zone_surface_void_middle = geom.zoneSurfaceVoidRatio and geom.zoneSurfaceVoidRatio[2] or geom.currentSurfaceVoidRatio
    data.cooling_zone_surface_void_inner = geom.zoneSurfaceVoidRatio and geom.zoneSurfaceVoidRatio[3] or geom.currentSurfaceVoidRatio
    data.groove_forced_air_share_outer = geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[1] or (1/3)
    data.groove_forced_air_share_middle = geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[2] or (1/3)
    data.groove_forced_air_share_inner = geom.grooveForcedAirZoneShare and geom.grooveForcedAirZoneShare[3] or (1/3)
    data.ground_cooling_share_outer = geom.groundCoolingZoneShare and geom.groundCoolingZoneShare[1] or finiteNumber(contactWeights[1],1/3)
    data.ground_cooling_share_middle = geom.groundCoolingZoneShare and geom.groundCoolingZoneShare[2] or finiteNumber(contactWeights[2],1/3)
    data.ground_cooling_share_inner = geom.groundCoolingZoneShare and geom.groundCoolingZoneShare[3] or finiteNumber(contactWeights[3],1/3)
    data.groove_forced_air_speed_mps = geom.grooveForcedAirSpeedMps
    data.groove_forced_h_w_m2_k = geom.grooveForcedH_Wm2K
    data.groove_forced_conductance_w_k = geom.grooveForcedAirConductance
    data.groove_forced_cooling_w = geom.grooveForcedCoolingW
    data.thin_surface_heat_capacity_j_k = geom.thinSurfaceHeatCapacity
    data.skin_heat_capacity_j_k = geom.skinHeatCapacity
    data.core_heat_capacity_j_k = geom.coreHeatCapacity
    data.sidewall_heat_capacity_j_k = finiteNumber(geom.sidewallHeatCapacity, data.sidewall_heat_capacity_j_k or 0)
    data.old_lumped_core_heat_capacity_j_k = finiteNumber(geom.oldLumpedCoreHeatCapacity, geom.coreHeatCapacity)
    data.surface_avg_temp = TempRingsToAvgTemp(data.surface_temp, loadBias, contactWeights)
    data.bulk_tread_avg_temp = avgBulkAfter
    data.grip_depth_avg_temp = avgSkinAfter
    data.thermal_brush_utilization = thermalBrushUtilization
    data.thermal_sliding_load_fraction = thermalSlidingLoadFraction
    data.structural_brush_stiffness_factor = thermalStructure and thermalStructure.stiffnessFactor or 1
    data.structural_brush_aspect_ratio = thermalStructure and thermalStructure.aspectRatio or 0
    data.structural_brush_sidewall_height_m = thermalStructure and thermalStructure.sidewallHeightM or 0
    data.structural_brush_live_pressure_psi = thermalStructure and thermalStructure.livePressurePsi
        or (math.max(finiteNumber(geom.actualPressure, geom.safePressure), 0) / PSI_TO_PA)
    data.structural_brush_critical_angle_deg = thermalStructure and thermalStructure.criticalAngleDeg or math.deg(math.atan(thermalCriticalY))
    data.structural_brush_geometry_valid = thermalStructure and thermalStructure.geometryValid == true or false
    data.structural_brush_dynamic_fiala = thermalStructure and thermalStructure.dynamicFiala == true or false
    data.structural_brush_load_ratio = thermalStructure and thermalStructure.loadRatio or 1
    data.structural_brush_load_shape = thermalStructure and thermalStructure.corneringStiffnessLoadShape or 1
    data.structural_brush_wear_stiffness_factor = thermalStructure and thermalStructure.wearStiffnessFactor or 1
    data.structural_brush_wear_requested_stiffness_factor = thermalStructure and thermalStructure.wearRequestedStiffnessFactor or 1
    data.structural_brush_wear_depth_ratio = thermalStructure and thermalStructure.wearDepthRatio or 1
    data.structural_brush_wear_stiffness_mode = thermalStructure and thermalStructure.wearStiffnessMode or "unknown"
    data.structural_brush_wear_compliance_share = thermalStructure and thermalStructure.wearComplianceShare or 0
    data.structural_brush_wear_remaining_depth_m = thermalStructure and thermalStructure.wearRemainingDepthM or 0
    data.structural_brush_wear_reference_depth_m = thermalStructure and thermalStructure.wearReferenceDepthM or 0
    data.structural_brush_thermal_stiffness_factor = thermalStructure and thermalStructure.thermalCorneringStiffnessFactor or 1
    data.structural_brush_structural_temp_c = thermalStructure and thermalStructure.structuralTreadTempC or avgBulkAfter
    data.structural_brush_mu_thermal_scale = thermalStructure and thermalStructure.muThermalScaleUsed or thermalCriticalMuScale
    data.contact_zone_weights = {contactWeights[1], contactWeights[2], contactWeights[3]}
    data.flex_heat_zone_weights = {flexWeights[1], flexWeights[2], flexWeights[3]}
    data.rolling_heat_zone_weights = {rollingZoneWeights[1], rollingZoneWeights[2], rollingZoneWeights[3]}
    data.cross_tread_reference_pressure_psi = referencePressurePsiForZones
    data.cross_tread_reference_pressure_source = referencePressureSourceForZones
    data.cross_tread_deflection_index = finiteNumber(crossTreadState and crossTreadState.deflectionIndex, 1)
    data.cross_tread_shoulder_center_ratio = finiteNumber(crossTreadState and crossTreadState.shoulderCenterRatio, 1)
    data.cross_tread_flex_shoulder_center_ratio = finiteNumber(crossTreadState and crossTreadState.flexShoulderCenterRatio, 1)
    data.cross_tread_compliance = finiteNumber(crossTreadState and crossTreadState.compliance, 1)
    data.cross_tread_effective_compliance = finiteNumber(crossTreadState and crossTreadState.effectiveCompliance,
        data.cross_tread_compliance)
    data.cross_tread_raw_load_ratio = finiteNumber(crossTreadState and crossTreadState.rawLoadRatio, geom.loadRatio)
    data.cross_tread_effective_load_ratio = finiteNumber(crossTreadState and crossTreadState.effectiveLoadRatio,
        data.cross_tread_raw_load_ratio)
    data.cross_tread_raw_pressure_ratio = finiteNumber(crossTreadState and crossTreadState.rawPressureRatio, 1)
    data.cross_tread_effective_pressure_ratio = finiteNumber(crossTreadState and crossTreadState.effectivePressureRatio,
        data.cross_tread_raw_pressure_ratio)
    data.cross_tread_crown_support_ratio = finiteNumber(crossTreadState and crossTreadState.crownSupportRatio, 0)
    data.cross_tread_crown_load_authority = finiteNumber(crossTreadState and crossTreadState.crownLoadAuthority, 1)
    data.cross_tread_crown_pressure_authority = finiteNumber(crossTreadState and crossTreadState.crownPressureAuthority, 1)
    data.cross_tread_crown_flex_authority = finiteNumber(crossTreadState and crossTreadState.crownFlexAuthority, 1)
    data.cross_tread_lateral_demand = finiteNumber(crossTreadState and crossTreadState.lateralDemand, 0)
    data.cross_tread_flex_strain_proxy = finiteNumber(crossTreadState and crossTreadState.flexStrainProxy, 0)
    data.cross_tread_lateral_hysteresis_gain = finiteNumber(crossTreadState and crossTreadState.hysteresisComplianceGain, 1)
    data.heat_wear_depth_ratio = finiteNumber(wearDepthHeatScale.depthRatio, 1.0)
    data.heat_wear_depth_volume_factor = finiteNumber(wearDepthHeatScale.volumeFactor, 1.0)
    data.heat_wear_depth_rolling_scale = finiteNumber(wearDepthHeatScale.rolling, 1.0)
    data.heat_wear_depth_longitudinal_scale = finiteNumber(wearDepthHeatScale.longitudinal, 1.0)
    data.heat_wear_depth_lateral_scale = finiteNumber(wearDepthHeatScale.lateral, 1.0)
    data.heat_deformation_longitudinal_w = longitudinalDeformationHeatW
    data.heat_deformation_lateral_w = lateralDeformationHeatW
    data.heat_deformation_tread_w = longitudinalTreadHeatW + lateralTreadHeatW
    data.heat_deformation_sidewall_w = longitudinalSidewallHeatW + lateralSidewallHeatW
    data.heat_deformation_core_w = longitudinalCoreHeatW + lateralCoreHeatW
    data.heat_deformation_sidewall_outer_w = finiteNumber(geom.sidewallOuterFlexHeatW, 0)
    data.heat_deformation_sidewall_inner_w = finiteNumber(geom.sidewallInnerFlexHeatW, 0)
    data.heat_extra_flex_hysteresis_fraction = extraFlexBaseFraction
    data.heat_true_sliding_fraction = trueSlidingFraction
    data.heat_adhesion_deformation_fraction = adhesionDeformationFraction
    data.heat_brush_mechanical_w = totalBrushMechanicalPowerW
    data.heat_brush_longitudinal_mechanical_w = longitudinalMechanicalSlipPowerW
    data.heat_brush_lateral_mechanical_w = lateralMechanicalSlipPowerW
    data.heat_sliding_mechanical_w = slidingMechanicalPowerW
    data.flash_excitation_w = flashExcitationPowerW
    data.flash_to_surface_w = flashToSurfaceW
    data.heat_roll_mechanical_loss_w = rollingMechanicalLossW
    data.heat_roll_retained_fraction = clamp(finiteNumber(M._tread1D.rollingTyreRetainedFraction, 0.90), 0, 1)
    data.heat_roll_w = rollingHeatW
    data.heat_roll_tread_w = rollingTreadHeatW
    data.heat_roll_sidewall_w = finiteNumber(geom.sidewallRollingHeatW, 0)
    data.heat_roll_sidewall_outer_w = finiteNumber(geom.sidewallOuterRollingHeatW, 0)
    data.heat_roll_sidewall_inner_w = finiteNumber(geom.sidewallInnerRollingHeatW, 0)
    data.heat_roll_sidewall_outer_share = finiteNumber(geom.sidewallOuterHeatShare, 0.5)
    data.heat_roll_sidewall_inner_share = finiteNumber(geom.sidewallInnerHeatShare, 0.5)
    data.sidewall_flex_split_proxy = finiteNumber(geom.sidewallFlexSplitProxy, 0)
    data.sidewall_flex_split_exponent = finiteNumber(geom.sidewallFlexSplitExponent, 1)
    data.heat_roll_core_w = finiteNumber(geom.rollingCoreHeatW, rollingHeatW - rollingTreadHeatW)
    data.heat_roll_tread_share = M._tread1D.treadRollingHeatShare
    data.heat_roll_sidewall_share = finiteNumber(geom.sidewallRollingHeatShare, 0)
    data.heat_roll_core_share = rollingHeatW > 1e-9 and finiteNumber(geom.rollingCoreHeatW, 0) / rollingHeatW or 0
    data.heat_deformation_w = deformationHeatW
    data.thermal_sliding_length_fraction = thermalSlidingLengthFraction
    data.thermal_sliding_load_fraction = thermalSlidingLoadFraction
    data.thermal_local_slip_velocity_factor = localSlidingVelocityFactor
    data.thermal_dissipation_fraction = thermalDissipationFraction
    data.heat_slip_raw_w = rawSlipHeatW
    data.heat_slip_gross_retained_w = grossSlipHeatW
    data.heat_destruction_energy_demand_w = wearModel.destructionEnergyDemandW
    data.heat_destruction_energy_sink_w = wearModel.destructionEnergySinkW
    data.heat_destruction_energy_limited_by_gross = wearModel.destructionEnergyDemandW > wearModel.destructionEnergyCapW + 1e-9
    data.heat_destruction_energy_enthalpy_j_per_kg = finiteNumber(wearModel.destructionEnthalpyJPerKg,0)
    data.heat_destruction_removed_mass_kg_step = finiteNumber(wearModel.removedMassKgStep,0)
    data.heat_destruction_activated_mass_kg_step = finiteNumber(wearModel.activatedDestroyedMassKgStep,0)
    data.heat_destruction_activation = finiteNumber(wearModel.meanDestructionActivation,0)
    data.heat_destruction_predicted_flash_c = finiteNumber(wearModel.predictedFlashTempC,predictedFlashTempC)
    data.heat_destruction_model = "cambridge-mass-owned-200kJkg-smoothstep-no-extra-wear"
    data.heat_slip_legacy_combined_w = legacyCombinedSlipHeatW
    data.heat_longitudinal_fiala_u = longitudinalFialaUtilization
    data.heat_longitudinal_fiala_force_fraction = longitudinalFialaForceFraction
    data.heat_longitudinal_fiala_force_n = finiteNumber(geom.legacyHeatForceLongitudinalN, longitudinalFialaForceEstimateN)
    data.heat_longitudinal_force_used_n = longitudinalFialaForceEstimateN
    data.heat_longitudinal_mechanical_slip_power_w = longitudinalMechanicalSlipPowerW
    data.heat_lateral_fiala_u = lateralFialaUtilization
    data.heat_lateral_fiala_force_fraction = lateralFialaForceFraction
    data.heat_lateral_fiala_force_n = finiteNumber(geom.legacyHeatForceLateralN, lateralFialaForceEstimateN)
    data.heat_lateral_force_used_n = lateralFialaForceEstimateN
    data.heat_lateral_mechanical_slip_power_w = lateralMechanicalSlipPowerW
    data.heat_force_source = nativeSlipPowerValid
        and "beamng-wheelRotator-slipEnergy-direct-sliding-power" or "legacy-fiala-mu-fallback"
    data.heat_native_slip_power_valid = nativeSlipPowerValid
    data.heat_native_slip_power_w = nativeSlipPowerW
    data.heat_native_slip_power_longitudinal_w = nativeLongitudinalSlipPowerW
    data.heat_native_slip_power_lateral_w = nativeLateralSlipPowerW
    data.heat_native_slip_power_bypasses_b = nativeSlipPowerValid
    data.heat_native_slip_power_source = nativeSlipPowerValid and tostring(geom.nativeSlipPower.source or "unknown")
        or tostring(M._physicalThermal.nativeSlipPowerSource.lastSource or "fallback")
    data.heat_native_equivalent_force_fx_n = nativeSlipPowerValid and finiteNumber(geom.nativeSlipPower.equivalentFxN, 0) or 0
    data.heat_native_equivalent_force_fy_n = nativeSlipPowerValid and finiteNumber(geom.nativeSlipPower.equivalentFyN, 0) or 0
    data.heat_native_equivalent_force_tangential_n = nativeSlipPowerValid
        and finiteNumber(geom.nativeSlipPower.equivalentTangentialForceN, 0) or 0
    data.heat_native_beamng_last_slip_mps = nativeSlipPowerValid
        and finiteNumber(geom.nativeSlipPower.beamngLastSlipMps, 0) or 0

    data.heat_combined_force_circle_scale = combinedForceScale
    data.heat_lateral_research_retained_w = lateralResearchHeatW
    data.heat_slip_stored_w = slipHeatW
    data.heat_slip_circumferential_local_w = finiteNumber(geom.circ.localHeatW, 0)
    data.heat_slip_circumferential_bulk_w = finiteNumber(geom.circ.bulkHeatW, slipHeatW)
    data.circumferential_model = M._circumferential.modelVersion
    data.heat_interface_mu = interfaceMuForHeat
    data.bulk_ground_conductance_w_per_k = totalGroundConductance
    data.heat_native_node_ratio = heatFrictionState.nodeRatio
    data.heat_native_ultimate_ratio = heatFrictionState.ultimateRatio
    data.heat_applied_grip_scale = heatFrictionState.appliedGripScale
    data.heat_slip_distance_per_pass_m = thermalSlipDistancePerPassM
    data.heat_surface_localization = surfaceLocalizationFactor
    data.heat_flash_localization = slipLocalization
    data.cool_skin_air_w = totalSkinAirCoolingW
    data.cool_ground_w = totalGroundCoolingW
    data.cool_sliding_w = totalSlidingCoolingW
    data.cool_radiation_w = totalRadiationW
    data.cool_degradation_w = totalDegradationW
    data.hot_acceptance = hotAcceptance

    -- Measured local-abrasion remap. Wear is generated only by the
    -- brush sliding region: the sticking region has no bristle sliding and therefore
    -- no direct abrasive wear.  We use the Cambridge bi-linear local wear law with
    -- live local pressure, a reduced-order mean sliding-zone speed and the fraction of
    -- time a tread element actually spends inside the footprint. Wheel RPM and
    -- BeamNG lastSlip do not create independent duplicate wear channels.
    -- Cambridge wear was prepared before the thermal source transaction so
    -- its removed mass could own Q_destroy. Do NOT recalculate it here; commit that same
    -- packet exactly once, preserving the existing wear mass owner and deadband logic.
    -- Preserve the existing circumference-average tread-depth/mass accounting, but
    -- remember what fraction of that wear occurred on a specific angular sector.
    -- The sparse wear field is mean-zero around the already-updated average depth,
    -- so local flatspot memory adds no duplicate wear mass.
    -- ordinary localized wear still follows the >=0.1% physical write
    -- packet. Wear generated while microscopic flash is beyond the ablation knee is
    -- additionally tagged for the rare >=10um / max-60Hz destructive-skin turnover.
    local didWearThermalRemesh = ApplyTreadWearAndRemesh(wheelID, data, physical, profile, geom.nominalTreadDepth,
        wearModel.zoneDepthM, wearModel.zoneFlashFastDepthM, contactWeights, loadBias)
    M._circumferential.refreshContactWear(data, geom.nominalTreadDepth)
    if didWearThermalRemesh then
        M._circumferential.refreshContactThermal(data, geom, loadBias, contactWeights,
            M._thermalGripCacheByWheel[wheelID])
        data.post_wear_contact_thermal_refresh_count=finiteNumber(data.post_wear_contact_thermal_refresh_count,0)+1
    end
    M._rallyDirt.updateEdgeTelemetry(data)

    data.wear_model = "research-bilinear-brush-B-load-real-slip-native-friction-work-mass-owned-destruction-energy-v6"
    data.wear_model_k1 = wearModel.k1
    data.wear_model_k2 = wearModel.k2
    data.wear_model_local_slip_factor = wearModel.localSlipFactor
    data.wear_model_local_slip_speed_mps = wearModel.localSlipSpeed
    data.wear_model_abrasion_sliding_scale = wearModel.abrasionSlidingScale
    data.wear_model_sliding_fraction = wearModel.slidingFraction
    data.wear_model_contact_duty = wearModel.contactDuty
    data.wear_model_surface_scale = wearModel.surfaceScale
    data.wear_model_friction_work_authority = finiteNumber(wearModel.frictionWorkAuthority,1.0)
    data.wear_model_friction_work_raw_authority = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.rawAuthority,1.0)
    data.wear_model_friction_work_confidence = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.confidence,0)
    data.wear_model_friction_work_source = tostring(wearModel.frictionWorkState and wearModel.frictionWorkState.source or "unknown")
    data.wear_model_actual_slip_power_w = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.actualPowerW,0)
    data.wear_model_reference_dry_slip_power_w = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.referenceDryPowerW,0)
    data.wear_model_actual_equivalent_tangential_force_n = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.actualEquivalentForceN,0)
    data.wear_model_actual_equivalent_fx_n = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.equivalentFxN,0)
    data.wear_model_actual_equivalent_fy_n = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.equivalentFyN,0)
    data.wear_model_actual_sliding_patch_mu = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.actualSlidingPatchMu,0)
    data.wear_model_reference_dry_patch_mu = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.referenceDryPatchMu,0)
    data.wear_model_longitudinal_work_share = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.longitudinalWorkShare,0)
    data.wear_model_lateral_work_share = finiteNumber(wearModel.frictionWorkState and wearModel.frictionWorkState.lateralWorkShare,0)
    data.rally_block_height_wear_scale = finiteNumber(
        geom.rallyDirtCfg and geom.rallyDirtCfg.heightWearScale, 1.0)
    data.rally_block_edge_wear_scale = finiteNumber(
        geom.rallyDirtCfg and geom.rallyDirtCfg.edgeWearScale, 1.0)
    data.wear_model_effective_temp_c = wearModel.meanEffectiveTempC
    data.wear_model_zone_effective_temp_c = wearModel.zoneEffectiveTempC
    data.wear_model_zone_surface_temp_c = wearModel.zoneSurfaceTempC
    data.wear_model_zone_cell1_temp_c = wearModel.zoneCell1TempC
    data.wear_model_zone_cell2_temp_c = wearModel.zoneCell2TempC
    data.wear_model_zone_temp_weights = wearModel.zoneTempWeights
    data.wear_model_surface_authority = wearModel.meanSurfaceAuthority
    data.wear_model_zone_surface_authority = wearModel.zoneSurfaceAuthority
    data.wear_model_temp_multiplier = wearModel.meanTempMult
    data.wear_model_macro_temp_multiplier = wearModel.meanMacroTempMult
    data.wear_model_flash_temp_c = wearModel.meanFlashTempC
    data.wear_model_flash_internal_factor = wearModel.meanFlashInternalFactor
    data.wear_model_flash_hot_area_fraction = 0
    data.wear_model_flash_mass_authority = 0
    data.wear_model_flash_equivalent_extra = wearModel.meanFlashEquivalentExtra
    data.wear_model_flash_damage_knee_c = wearModel.flashDamageKneeC
    data.wear_model_flash_ablation_knee_c = wearModel.flashAblationKneeC
    data.wear_model_predicted_flash_temp_c = finiteNumber(wearModel.predictedFlashTempC,0)
    data.wear_model_destruction_activation = finiteNumber(wearModel.meanDestructionActivation,0)
    data.wear_model_zone_destruction_activation = wearModel.zoneDestructionActivation
    data.wear_model_removed_mass_kg_step = finiteNumber(wearModel.removedMassKgStep,0)
    data.wear_model_activated_destroyed_mass_kg_step = finiteNumber(wearModel.activatedDestroyedMassKgStep,0)
    data.wear_model_destruction_energy_demand_j = finiteNumber(wearModel.destructionEnergyDemandJ,0)
    data.wear_model_zone_macro_temp_multiplier = wearModel.zoneMacroTempMult
    data.wear_model_zone_flash_temp_c = wearModel.zoneFlashTempC
    data.wear_model_zone_flash_internal_factor = wearModel.zoneFlashInternalFactor
    data.wear_model_zone_flash_equivalent_extra = wearModel.zoneFlashEquivalentExtra
    data.wear_model_zone_flash_extra_depth_mm = {wearModel.zoneFlashExtraDepthM[1]*1000,wearModel.zoneFlashExtraDepthM[2]*1000,wearModel.zoneFlashExtraDepthM[3]*1000}
    data.wear_model_macro_depth_rate_mm_s = safeDt > 0 and (wearModel.meanMacroDepthStepM * 1000 / safeDt) or 0
    data.wear_model_flash_extra_depth_rate_mm_s = safeDt > 0 and (wearModel.meanFlashExtraDepthStepM * 1000 / safeDt) or 0
    data.wear_model_contact_pressure_mpa = wearModel.meanPressureMPa
    data.wear_model_depth_step_mm = wearModel.meanDepthStepM * 1000
    data.wear_model_depth_rate_mm_s = safeDt > 0 and (wearModel.meanDepthStepM * 1000 / safeDt) or 0
    data.wear_model_zone_temp_multiplier = wearModel.zoneTempMult
    data.wear_model_zone_pressure_mpa = wearModel.zonePressureMPa

    data.tread_cell_count = geom.treadCells
    data.tread_nominal_depth_m = geom.nominalTreadDepth
    data.tread_mean_remaining_depth_m = (finiteNumber(data.tread_remaining_depth_m[1], geom.nominalTreadDepth)
        + finiteNumber(data.tread_remaining_depth_m[2], geom.nominalTreadDepth)
        + finiteNumber(data.tread_remaining_depth_m[3], geom.nominalTreadDepth)) / 3
    data.tread_nonwearable_reserve_m = getNonWearableTreadReserveM(geom.nominalTreadDepth)
    data.tread_wearable_remaining_m = math.max(data.tread_mean_remaining_depth_m - data.tread_nonwearable_reserve_m, 0)
    data.thermal_effective_local_slip_speed_mps = effectiveLocalSlipSpeed

    tyreData[wheelID] = data
end

local function EstimateBeamNativeDryStribeck(wheelID, slipSpeed, slidingLoadFraction)
    local wd = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
    local asphalt = groundModels and (groundModels.ASPHALT or groundModels.asphalt) or nil
    asphalt = asphalt or {}

    local groundStatic = math.max(finiteNumber(asphalt.staticFrictionCoefficient, M._flashMemory.nativeStribeckFallbackStaticMu), 0.001)
    local groundSliding = math.max(finiteNumber(asphalt.slidingFrictionCoefficient, M._flashMemory.nativeStribeckFallbackSlidingMu), 0.001)
    local tyreStatic = math.max(finiteNumber(wd and wd.frictionCoef, 1.0), 0.001)
    local tyreSliding = math.max(finiteNumber(wd and wd.slidingFrictionCoef, tyreStatic), 0.001)
    local exponent = clamp(finiteNumber(wd and wd.stribeckExponent, M._flashMemory.nativeStribeckDefaultExponent), 0.10, 8.0)
    local velMult = clamp(finiteNumber(wd and wd.stribeckVelMult, M._flashMemory.nativeStribeckDefaultVelMult), 0.05, 10.0)
    local groundVs = math.max(finiteNumber(asphalt.stribeckVelocity, M._flashMemory.nativeStribeckFallbackVelocityMps), 0.05)
    local effectiveVs = math.max(groundVs * velMult, 0.05)

    local staticMu = groundStatic * tyreStatic
    local slidingMu = groundSliding * tyreSliding
    local ultimateRatio = clamp(slidingMu / math.max(staticMu, 0.001), 0.05, 2.0)
    local v = math.max(finiteNumber(slipSpeed, 0), 0)
    local x = v / effectiveVs
    local stribeckStaticWeight = math.exp(-(x ^ exponent))
    local slidingNodeRatio = ultimateRatio + (1 - ultimateRatio) * stribeckStaticWeight

    local B = clamp(finiteNumber(slidingLoadFraction, 0), 0, 1)
    local effectivePatchRatio = (1 - B) + B * slidingNodeRatio

    return {
        groundStatic = groundStatic,
        groundSliding = groundSliding,
        tyreStatic = tyreStatic,
        tyreSliding = tyreSliding,
        exponent = exponent,
        velMult = velMult,
        groundVelocity = groundVs,
        effectiveVelocity = effectiveVs,
        ultimateRatio = ultimateRatio,
        nodeRatio = slidingNodeRatio,
        patchRatio = effectivePatchRatio,
        staticWeight = stribeckStaticWeight,
    }
end

local function UpdateFlashMemoryGrip(wheelID, dt, roadSpeed, angularVelocity, radius, combinedSlipSpeed, longitudinalSlipSpeed, lateralSlipSpeed, loadBias, disabled, rallyHardRoadSurface)
    local data = tyreData[wheelID]
    local state = wheelFlashGripState[wheelID]
    if type(state) ~= "table" then
        state = {
            hotFraction = 0,
            gripMultiplier = 1,
            slipSpeed = 0,
            surfaceSpeed = 0,
            refreshRateHz = 0,
            residenceTimeS = 0,
            slipDistancePerPassM = 0,
            memoryX = 0,
            rawMemoryHotFraction = 0,
            brushSigmaX = 0,
            brushSigmaY = 0,
            brushUtilization = 0,
            brushSlidingLengthFraction = 0,
            brushSlidingLoadFraction = 0,
            brushCriticalSigmaXUsed = M._flashMemory.brushCriticalSigmaX,
            brushCriticalSigmaYUsed = M._flashMemory.brushCriticalSigmaYFallback,
            brushCriticalAngleDeg = math.deg(math.atan(M._flashMemory.brushCriticalSigmaYFallback)),
            brushCriticalThermalScale = 1,
            mechanicalResearchAuthority = 0,
            targetHotFraction = 0,
            nativeDryUltimateRatio = 1,
            nativeDryNodeRatio = 1,
            nativeDryPatchRatio = 1,
            nativeDryStribeckVelocity = 0,
            nativeDryStribeckExponent = M._flashMemory.nativeStribeckDefaultExponent,
            nativeDryTyreStaticCoef = 1,
            nativeDryTyreSlidingCoef = 1,
            nativeDeembedMultiplier = 1,
            mechanicalNativeRatio = 1,
            mechanicalTargetRatio = 1,
            mechanicalRawMultiplier = 1,
            mechanicalRemapMultiplier = 1,
            modelCurveEnabled = false,
            modelCurveProfile = "none",
            modelCurveBaseKineticRatio = 1,
            modelCurveKineticRatio = 1,
            modelCurveVelocityFactor = 1,
            modelCurveVelocityState = 0,
            modelCurveHistoryState = 0,
            modelCurveTargetPatchRatio = 1,
            modelCurveCommandedPatchRatio = 1,
            modelCurveAuthority = 0,
            modelCurveCorrectionMultiplier = 1,
            coolSlideFloorRatio = 1,
            hotSlideFloorRatio = 1,
            surfaceHeatState = 0,
            surfaceHeatDrive = 0,
            surfaceTempC = ENV_TEMP,
            surfaceThermalModifier = 1,
            shortTermSurfaceOverloadRawC = 0,
            shortTermSurfaceOverloadC = 0,
            shortTermSurfaceOverloadState = 0,
            shortTermSurfaceModifier = 1,
            directFastThermalMultiplier = 1,
            directSurfaceCellsGripMultiplier = 1,
            directSurfaceCellsGripMultiplierRealistic = 1,
            longTermSurfaceSlideRatio = 1,
            surfaceSlideRatio = 1,
            slipPlateauSource = "initial",
            flashTargetTotalRatio = 1,
            flashRiseC = 0,
            flashEquivalentBulkTemp = ENV_TEMP,
            flashThermalModifier = 1,
            lockRatio = 1,
            patchEffectiveTemp = ENV_TEMP,
            macroCurveGrip = 1,
        }
        wheelFlashGripState[wheelID] = state
    end

    local safeDt = clamp(finiteNumber(dt, 0), 0, 0.1)
    if type(data)=="table" then data.thermal_cache_age_ms=math.max(finiteNumber(data.thermal_cache_age_ms,0)+safeDt*1000,0) end
    local safeRadius = math.max(finiteNumber(radius, data and data.tyre_radius_m or 0.33), 0.01)
    local safeRoadSpeed = math.max(finiteNumber(roadSpeed, 0), 0)
    local surfaceSpeed = math.abs(finiteNumber(angularVelocity, 0)) * safeRadius
    local slipSpeed = math.max(finiteNumber(combinedSlipSpeed, 0), 0)
    local longitudinalSlip = math.max(finiteNumber(longitudinalSlipSpeed, 0), 0)
    local lateralSlip = math.max(finiteNumber(lateralSlipSpeed, 0), 0)
    local patchLength = clamp(finiteNumber(data and data.contact_patch_length_m, 0.08), 0.01, math.pi * safeRadius)
    local circumference = math.max(2 * math.pi * safeRadius, 0.01)
    local patchFraction = clamp(patchLength / circumference, 0.005, 0.35)
    local lockRatio = surfaceSpeed / math.max(safeRoadSpeed, 0.1)

    if disabled or type(data) ~= "table" then
        state.hotFraction = 0
        state.gripMultiplier = 1
        state.slipSpeed = slipSpeed
        state.surfaceSpeed = surfaceSpeed
        state.refreshRateHz = surfaceSpeed / patchLength
        state.residenceTimeS = patchLength / math.max(surfaceSpeed, M._flashMemory.minRefreshSpeedMps)
        state.slipDistancePerPassM = 0
        state.memoryX = 0
        state.rawMemoryHotFraction = 0
        state.brushSigmaX = 0
        state.brushSigmaY = 0
        state.brushUtilization = 0
        state.brushSlidingLengthFraction = 0
        state.brushSlidingLoadFraction = 0
        state.brushCriticalSigmaXUsed = M._flashMemory.brushCriticalSigmaX
        state.brushCriticalSigmaYUsed = M._flashMemory.brushCriticalSigmaYFallback
        state.brushCriticalAngleDeg = math.deg(math.atan(M._flashMemory.brushCriticalSigmaYFallback))
        state.brushCriticalThermalScale = 1
        state.mechanicalResearchAuthority = 0
        state.targetHotFraction = 0
        state.nativeDryUltimateRatio = 1
        state.nativeDryNodeRatio = 1
        state.nativeDryPatchRatio = 1
        state.nativeDryStribeckVelocity = 0
        state.nativeDryStribeckExponent = M._flashMemory.nativeStribeckDefaultExponent
        state.nativeDryTyreStaticCoef = 1
        state.nativeDryTyreSlidingCoef = 1
        state.nativeDeembedMultiplier = 1
        state.mechanicalNativeRatio = 1
        state.mechanicalTargetRatio = 1
        state.mechanicalRawMultiplier = 1
        state.mechanicalRemapMultiplier = 1
        state.modelCurveEnabled = false
        state.modelCurveProfile = "none"
        state.modelCurveBaseKineticRatio = 1
        state.modelCurveKineticRatio = 1
        state.modelCurveVelocityFactor = 1
        state.modelCurveVelocityState = 0
        state.modelCurveHistoryState = 0
        state.modelCurveTargetPatchRatio = 1
        state.modelCurveCommandedPatchRatio = 1
        state.modelCurveAuthority = 0
        state.modelCurveCorrectionMultiplier = 1
        state.coolSlideFloorRatio = 1
        state.hotSlideFloorRatio = 1
        state.surfaceHeatState = 0
        state.surfaceHeatDrive = 0
        state.surfaceTempC = data and TempRingsToAvgTemp(data.surface_temp or data.temp, loadBias, data.contact_zone_weights) or ENV_TEMP
        state.surfaceThermalModifier = 1
        state.shortTermSurfaceOverloadRawC = 0
        state.shortTermSurfaceOverloadC = 0
        state.shortTermSurfaceOverloadState = 0
        state.shortTermSurfaceModifier = 1
        state.directFastThermalMultiplier = 1
        state.directSurfaceCellsGripMultiplier = 1
        state.directSurfaceCellsGripMultiplierRealistic = 1
        state.longTermSurfaceSlideRatio = 1
        state.surfaceSlideRatio = 1
        state.slipPlateauSource = "disabled"
        state.flashTargetTotalRatio = 1
        state.flashRiseC = 0
        state.flashEquivalentBulkTemp = data and TempRingsToAvgTemp(data.surface_temp or data.temp, loadBias, data.contact_zone_weights) or ENV_TEMP
        state.flashThermalModifier = 1
        state.lockRatio = lockRatio
        state.patchEffectiveTemp = data and TempRingsToAvgTemp(data.surface_temp or data.temp, loadBias, data.contact_zone_weights) or ENV_TEMP
        state.macroCurveGrip = 1
        return 1, state
    end

    local thermalCache=M._thermalGripCacheByWheel and M._thermalGripCacheByWheel[wheelID] or nil
    local profile=thermalCache and thermalCache.profile or nil
    if type(profile)~="table" then
        local detectedTyre=getWheelTyreProfile(wheelID)
        profile=detectedTyre and detectedTyre.profile or TYRE_PROFILES.standard
    end
    local macroCurveGrip,macroCurveGripRealistic,macroTemp
    if thermalCache and thermalCache.macroCurveGrip then
        macroCurveGrip=finiteNumber(thermalCache.macroCurveGrip,1)
        macroCurveGripRealistic=finiteNumber(thermalCache.macroCurveGripRealistic,macroCurveGrip)
        macroTemp=finiteNumber(thermalCache.macroGripDepthTemp,finiteNumber(data.grip_depth_avg_temp,ENV_TEMP))
    else
        macroCurveGrip,macroCurveGripRealistic,macroTemp=M._tread1D.evaluateDirectSurfaceGrip(
            data,profile,loadBias,data.contact_zone_weights,false,thermalCache)
    end
    local surfaceTemp=finiteNumber(data.circumferential_contact_surface_temp_c,
        thermalCache and TempRingsToAvgTemp(thermalCache.surfaceTemp,loadBias,data.contact_zone_weights)
            or TempRingsToAvgTemp(data.surface_temp or data.temp,loadBias,data.contact_zone_weights))
    local surfaceGripTemp=finiteNumber(data.circumferential_contact_grip_depth_temp_c,
        thermalCache and finiteNumber(thermalCache.gripDepthAvgTemp,macroTemp)
            or finiteNumber(data.grip_depth_avg_temp,macroTemp))
    local flashTemp=math.max(finiteNumber(thermalCache and thermalCache.flashTemp,
        finiteNumber(data.flash_temp,surfaceTemp)),surfaceTemp)

    local criticalThermalMuScale = clamp(macroCurveGrip, 0.05, 1.0)
    local criticalThermalScale = clamp(criticalThermalMuScale, M._flashMemory.brushCriticalThermalScaleMin, 1.0)
    local gripBrushTable = M._flashMemory.brushCriticalSigmaYByProfile
    local baseCriticalSigmaY = finiteNumber(
        gripBrushTable[profile.id], M._flashMemory.brushCriticalSigmaYFallback)
    local brushCriticalSigmaXUsed = math.max(M._flashMemory.brushCriticalSigmaX * criticalThermalScale, 0.001)
    local brushCriticalSigmaYUsed,pressureWheelBrush=M._pressureWheelBrush.getCachedCriticalSigmaY(
        wheelID,data.brush_vertical_load_n)
    if brushCriticalSigmaYUsed==nil then
        brushCriticalSigmaYUsed,pressureWheelBrush=GetPressureWheelBrushCriticalSigmaY(
            wheelID,profile,baseCriticalSigmaY,criticalThermalMuScale,data.brush_vertical_load_n,nil)
    end
    local brushCriticalAngleDeg = pressureWheelBrush and pressureWheelBrush.criticalAngleDeg
        or math.deg(math.atan(brushCriticalSigmaYUsed))

    local targetHotFraction = 0
    local rawMemoryHotFraction = 0
    local slipDistancePerPass = 0
    local memoryX = 0
    local brushSigmaX = 0
    local brushSigmaY = 0
    local brushUtilization = 0
    local brushSlidingLengthFraction = 0
    local brushSlidingLoadFraction = 0

    if slipSpeed >= M._flashMemory.minSlipSpeedMps then
        local brushSurfaceSpeed = math.max(surfaceSpeed, M._flashMemory.brushMinSurfaceSpeedMps)
        brushSigmaX = longitudinalSlip / brushSurfaceSpeed
        brushSigmaY = lateralSlip / brushSurfaceSpeed
        local normX = brushSigmaX / brushCriticalSigmaXUsed
        local normY = brushSigmaY / brushCriticalSigmaYUsed
        brushUtilization = math.sqrt(normX * normX + normY * normY)
        brushSlidingLengthFraction = clamp(brushUtilization, 0, 1)

        local S = brushSlidingLengthFraction
        brushSlidingLoadFraction = clamp(S * S * (3 - 2 * S), 0, 1)

        if RT.lockedPatchFlashGripEnabled then
            local refreshSpeed = math.max(surfaceSpeed, M._flashMemory.minRefreshSpeedMps)
            slipDistancePerPass = slipSpeed * patchLength / refreshSpeed
            memoryX = slipDistancePerPass / math.max(M._flashMemory.slipMemoryLengthM, 0.0001)

            if surfaceSpeed <= M._flashMemory.minRefreshSpeedMps then
                rawMemoryHotFraction = 1
            elseif memoryX < 0.0001 then
                rawMemoryHotFraction = memoryX * 0.5 - memoryX * memoryX / 6
            else
                rawMemoryHotFraction = 1 - (1 - math.exp(-memoryX)) / memoryX
            end
            rawMemoryHotFraction = clamp(rawMemoryHotFraction, 0, 1)
            targetHotFraction = clamp(rawMemoryHotFraction * brushSlidingLoadFraction, 0, 1)
        end
    end

    local oldHotFraction = clamp(finiteNumber(state.hotFraction, 0), 0, 1)
    local tau
    if targetHotFraction >= oldHotFraction then
        tau = clamp(patchLength / math.max(surfaceSpeed + slipSpeed, 0.1),
            M._flashMemory.buildTauFloorS, M._flashMemory.buildTauCeilS)
    else
        local refreshRate = surfaceSpeed / patchLength
        local totalReleaseRate = refreshRate + 1 / math.max(M._flashMemory.thermalReleaseTauS, 0.001)
        tau = 1 / math.max(totalReleaseRate, 1)
    end
    local alpha = safeDt > 0 and (1 - math.exp(-safeDt / math.max(tau, 0.0005))) or 1
    state.hotFraction = clamp(oldHotFraction + (targetHotFraction - oldHotFraction) * alpha, 0, 1)

    local flashRiseC = math.max(flashTemp - surfaceTemp, 0)
    local flashEquivalentBulkTemp = profile.workingTemp
        + flashRiseC * clamp(M._flashMemory.flashLocalToBulkEquivalentScale, 0, 2.0)
    local flashEquivalentGrip = interpolateProfileGrip(profile, flashEquivalentBulkTemp)
    if flashEquivalentBulkTemp > profile.overheatStart then
        flashEquivalentGrip = clamp(1 - (1 - flashEquivalentGrip) * HOT_GRIP_LOSS_FACTOR, 0.05, 1.0)
    end
    local flashReferenceGrip = interpolateProfileGrip(profile, profile.workingTemp)
    local flashThermalModifier = clamp(flashEquivalentGrip / math.max(flashReferenceGrip, 0.001),
        M._flashMemory.minGripMultiplier, 1.0)
    flashThermalModifier = M._arcadeHandling.applyThermalPenalty(flashThermalModifier)

    --
    local native = EstimateBeamNativeDryStribeck(wheelID, slipSpeed, brushSlidingLoadFraction)
    local B = clamp(brushSlidingLoadFraction, 0, 1)
    local H = RT.lockedPatchFlashGripEnabled and clamp(math.min(state.hotFraction, B), 0, 1) or 0
    local nativeOgRatio = clamp(native.patchRatio, 0.05, 2.0)
    local ultimateRatio = clamp(native.ultimateRatio, 0.05, 2.0)

    local coolSlideFloor, hotSlideFloor, slipPlateauSource = getSlipPlateauRatios(wheelID, ultimateRatio)

    local surfaceHeatState = 0
    local surfaceHeatDrive = 0
    if M._slipPlateau and M._slipPlateau.enabled and M._slipPlateau.surfaceHeatEnabled then
        local fadeStartAbove = math.max(finiteNumber(
            M._slipPlateau.surfaceGripFadeStartAboveWorkingC[profile.id], 10), 0)
        local saturationAbove = math.max(finiteNumber(
            M._slipPlateau.surfaceGripSaturationAboveWorkingC[profile.id], 60), fadeStartAbove + 1)
        local fadeStartTemp = data.working_temp + fadeStartAbove
        local saturationTemp = data.working_temp + saturationAbove
        local u = clamp((surfaceGripTemp - fadeStartTemp) / math.max(saturationTemp - fadeStartTemp, 0.1), 0, 1)
        local smoothU = u * u * (3 - 2 * u)
        local responseExponent = clamp(finiteNumber(
            M._slipPlateau.surfaceGripResponseExponentByProfile[profile.id], 0.60), 0.10, 3.0)
        surfaceHeatState = smoothU ^ responseExponent
        surfaceHeatDrive = clamp((surfaceGripTemp - data.working_temp) / math.max(saturationAbove, 1), 0, 1)
    end

    local shortTermSurfaceOverloadRawC = clamp(
        math.max(surfaceTemp - surfaceGripTemp, 0),
        0,
        math.max(finiteNumber(M._slipPlateau.shortTermMaxOverloadC, 180), 1))
    local previousShortTermOverloadC = clamp(
        finiteNumber(state.shortTermSurfaceOverloadC, 0),
        0,
        math.max(finiteNumber(M._slipPlateau.shortTermMaxOverloadC, 180), 1))
    local shortTermTau = shortTermSurfaceOverloadRawC >= previousShortTermOverloadC
        and math.max(finiteNumber(M._slipPlateau.shortTermRiseTauS, 0.16), 0.01)
        or math.max(finiteNumber(M._slipPlateau.shortTermReleaseTauS, 0.30), 0.01)
    local shortTermAlpha = safeDt > 0 and (1 - math.exp(-safeDt / shortTermTau)) or 1
    local shortTermSurfaceOverloadC = clamp(
        previousShortTermOverloadC
            + (shortTermSurfaceOverloadRawC - previousShortTermOverloadC) * shortTermAlpha,
        0,
        math.max(finiteNumber(M._slipPlateau.shortTermMaxOverloadC, 180), 1))

    local shortTermSurfaceOverloadState = 0
    local shortTermSurfaceModifier = 1
    if M._slipPlateau.shortTermSurfaceOverloadEnabled then
        local shortOnset = math.max(finiteNumber(
            profile.shortTermOnsetC or M._slipPlateau.shortTermOnsetAboveGripDepthC[profile.id], 15), 0)
        local shortSaturation = math.max(finiteNumber(
            profile.shortTermSaturationC or M._slipPlateau.shortTermSaturationAboveGripDepthC[profile.id], 105), shortOnset + 1)
        local shortU = clamp((shortTermSurfaceOverloadC - shortOnset)
            / math.max(shortSaturation - shortOnset, 0.1), 0, 1)
        local shortSmooth = shortU * shortU * (3 - 2 * shortU)
        local shortExponent = clamp(finiteNumber(
            profile.shortTermResponseExponent or M._slipPlateau.shortTermResponseExponentByProfile[profile.id], 0.75), 0.10, 3.0)
        shortTermSurfaceOverloadState = shortSmooth ^ shortExponent
        local shortMin = clamp(finiteNumber(
            profile.shortTermMinGrip or M._slipPlateau.shortTermMinGripMultiplierByProfile[profile.id], 0.80),
            M._flashMemory.minGripMultiplier, 1.0)
        shortTermSurfaceModifier = clamp(
            1 - (1 - shortMin) * shortTermSurfaceOverloadState,
            shortMin, 1.0)
    end

    shortTermSurfaceModifier = M._arcadeHandling.applyThermalPenalty(shortTermSurfaceModifier)

    local localSurfaceGrip, localSurfaceGripRealistic = M._tread1D.evaluateDirectSurfaceGrip(
        data, profile, loadBias, data.contact_zone_weights, true, thermalCache)
    local surfaceThermalModifier = clamp(
        localSurfaceGripRealistic / math.max(macroCurveGripRealistic, 0.001),
        M._flashMemory.minGripMultiplier, 1.0)
    surfaceThermalModifier = M._arcadeHandling.applyThermalPenalty(surfaceThermalModifier)
    surfaceHeatState = clamp(1 - surfaceThermalModifier, 0, 1)

    local longTermSurfaceSlideRatio = coolSlideFloor
    local surfaceSlideRatio = coolSlideFloor
    local directFastThermalMultiplier = clamp(
        surfaceThermalModifier * shortTermSurfaceModifier,
        M._flashMemory.minGripMultiplier, 1.0)

    --
    local brushMechanicalTargetRatio = clamp((1 - B) + B * coolSlideFloor, 0.05, 2.0)
    local rawMechanicalMultiplier = 1
    local mechanicalResearchAuthority = 0
    local mechanicalRemapMultiplier = 1
    local deembedMultiplier = 1

    local modelCurve = nil
    local globalCurveCfg = M._modelOwnedGripCurve or {}
    local globalCurveEnabled = globalCurveCfg.enabled ~= false
        and (not globalCurveCfg.enabledByProfile
            or globalCurveCfg.enabledByProfile[profile.id] ~= false)
    local isRallyProfile = profile.id == "rally_asphalt" or profile.id == "rally_gravel"

    if isRallyProfile and rallyHardRoadSurface ~= true then
        local thermalOnlyMultiplier = clamp(
            shortTermSurfaceModifier * surfaceThermalModifier,
            M._flashMemory.minGripMultiplier, 1.0)
        state.gripMultiplier = M._rallyDirt.limitFastGrip(
            thermalOnlyMultiplier, data.rally_surface_class)
        rawMechanicalMultiplier = 1
        mechanicalRemapMultiplier = 1
        mechanicalResearchAuthority = 0
        deembedMultiplier = state.gripMultiplier
    elseif globalCurveEnabled then

        modelCurve = M._modelOwnedGripCurve.evaluatePatchRatio(
            profile.id, B, brushUtilization, H, slipSpeed, coolSlideFloor, nativeOgRatio)

        mechanicalResearchAuthority = modelCurve.authority
        rawMechanicalMultiplier = modelCurve.correctionMultiplier
        mechanicalRemapMultiplier = modelCurve.correctionMultiplier
        deembedMultiplier = modelCurve.correctionMultiplier

        state.gripMultiplier = clamp(
            modelCurve.correctionMultiplier,
            M._flashMemory.minGripMultiplier,
            M._flashMemory.mechanicalSlipRemapMaxMultiplier)
    else
        state.gripMultiplier = 1.0
        rawMechanicalMultiplier = 1
        mechanicalRemapMultiplier = 1
        mechanicalResearchAuthority = 0
        deembedMultiplier = 1.0
    end

    local nativeDryPatchRatio = clamp(native.patchRatio, 0.05, 2.0)

    state.nativeDryUltimateRatio = native.ultimateRatio
    state.nativeDryNodeRatio = native.nodeRatio
    state.nativeDryPatchRatio = nativeDryPatchRatio
    state.nativeDryStribeckVelocity = native.effectiveVelocity
    state.nativeDryStribeckExponent = native.exponent
    state.nativeDryTyreStaticCoef = native.tyreStatic
    state.nativeDryTyreSlidingCoef = native.tyreSliding
    state.nativeDeembedMultiplier = deembedMultiplier
    state.mechanicalNativeRatio = nativeOgRatio
    state.mechanicalTargetRatio = brushMechanicalTargetRatio
    state.mechanicalRawMultiplier = rawMechanicalMultiplier
    state.mechanicalRemapMultiplier = mechanicalRemapMultiplier
    state.modelCurveEnabled = modelCurve ~= nil
    state.modelCurveProfile = modelCurve and modelCurve.profileId or "thermal-only"
    state.modelCurveBaseKineticRatio = modelCurve and modelCurve.baseKineticRatio or surfaceSlideRatio
    state.modelCurveKineticRatio = modelCurve and modelCurve.kineticRatio or surfaceSlideRatio
    state.modelCurveVelocityFactor = modelCurve and modelCurve.kineticVelocityFactor or 1
    state.modelCurveVelocityState = modelCurve and modelCurve.speedState or 0
    state.modelCurveHistoryState = modelCurve and modelCurve.historyState or 0
    state.modelCurveTargetPatchRatio = modelCurve and modelCurve.modelPatchRatio
        or ((1 - B) + B * surfaceSlideRatio)
    state.modelCurveCommandedPatchRatio = modelCurve and modelCurve.commandedPatchRatio
        or (nativeOgRatio * state.gripMultiplier)
    state.modelCurveBaseAuthority = modelCurve and modelCurve.baseAuthority or mechanicalResearchAuthority
    state.modelCurveDownwardPeakGate = modelCurve and modelCurve.downwardPeakGate or 1
    state.modelCurveAuthority = modelCurve and modelCurve.authority or mechanicalResearchAuthority
    state.modelCurveCorrectionMultiplier = modelCurve and modelCurve.correctionMultiplier
        or state.gripMultiplier
    state.rallyProfileActive = isRallyProfile
    state.rallyHardRoadSurface = rallyHardRoadSurface == true
    state.rallyNativeTerrainHandoff = isRallyProfile and rallyHardRoadSurface ~= true
    state.coolSlideFloorRatio = coolSlideFloor
    state.hotSlideFloorRatio = hotSlideFloor
    state.surfaceHeatState = surfaceHeatState
    state.surfaceHeatDrive = surfaceHeatDrive
    state.surfaceTempC = surfaceTemp
    state.gripDepthTempC = surfaceGripTemp
    state.surfaceThermalModifier = surfaceThermalModifier
    state.directFastThermalMultiplier = directFastThermalMultiplier
    state.directSurfaceCellsGripMultiplier = macroCurveGrip
    state.directSurfaceCellsGripMultiplierRealistic = macroCurveGripRealistic
    state.shortTermSurfaceOverloadRawC = shortTermSurfaceOverloadRawC
    state.shortTermSurfaceOverloadC = shortTermSurfaceOverloadC
    state.shortTermSurfaceOverloadState = shortTermSurfaceOverloadState
    state.shortTermSurfaceModifier = shortTermSurfaceModifier
    state.longTermSurfaceSlideRatio = longTermSurfaceSlideRatio
    state.surfaceSlideRatio = surfaceSlideRatio
    state.slipPlateauSource = slipPlateauSource
    state.flashTargetTotalRatio = flashTargetRatio
    state.flashRiseC = flashRiseC
    state.flashEquivalentBulkTemp = flashEquivalentBulkTemp
    state.flashThermalModifier = flashThermalModifier

    state.patchEffectiveTemp = surfaceGripTemp + shortTermSurfaceOverloadC
    state.macroCurveGrip = macroCurveGrip
    state.slipSpeed = slipSpeed
    state.surfaceSpeed = surfaceSpeed
    state.refreshRateHz = surfaceSpeed / patchLength
    state.residenceTimeS = patchLength / math.max(surfaceSpeed, M._flashMemory.minRefreshSpeedMps)
    state.slipDistancePerPassM = slipDistancePerPass
    state.memoryX = memoryX
    state.rawMemoryHotFraction = rawMemoryHotFraction
    state.brushSigmaX = brushSigmaX
    state.brushSigmaY = brushSigmaY
    state.brushUtilization = brushUtilization
    state.brushSlidingLengthFraction = brushSlidingLengthFraction
    state.brushSlidingLoadFraction = brushSlidingLoadFraction
    state.brushCriticalSigmaXUsed = brushCriticalSigmaXUsed
    state.brushCriticalSigmaYUsed = brushCriticalSigmaYUsed
    state.brushCriticalAngleDeg = brushCriticalAngleDeg
    state.brushCriticalThermalScale = pressureWheelBrush and pressureWheelBrush.muThermalScaleUsed or criticalThermalMuScale
    state.brushCriticalLongitudinalThermalScale = criticalThermalScale
    state.structuralBrushThermalStiffnessFactor = pressureWheelBrush and pressureWheelBrush.thermalCorneringStiffnessFactor or 1
    state.structuralBrushStructuralTempC = pressureWheelBrush and pressureWheelBrush.structuralTreadTempC or macroTemp
    state.structuralBrushEnabled = M._pressureWheelBrush and M._pressureWheelBrush.enabled == true
    state.structuralBrushGeometryValid = pressureWheelBrush and pressureWheelBrush.geometryValid == true or false
    state.structuralBrushStiffnessFactor = pressureWheelBrush and pressureWheelBrush.stiffnessFactor or 1
    state.structuralBrushJbeamValid = pressureWheelBrush and pressureWheelBrush.jbeamStructureValid == true or false
    state.structuralBrushJbeamFactor = pressureWheelBrush and pressureWheelBrush.jbeamStructureFactor or 1
    state.structuralBrushAspectRatio = pressureWheelBrush and pressureWheelBrush.aspectRatio or 0
    state.structuralBrushSidewallHeightM = pressureWheelBrush and pressureWheelBrush.sidewallHeightM or 0
    state.structuralBrushWidthM = pressureWheelBrush and pressureWheelBrush.widthM or 0
    state.structuralBrushLivePressurePsi = pressureWheelBrush and pressureWheelBrush.livePressurePsi or 0
    state.structuralBrushReferenceAspect = pressureWheelBrush and pressureWheelBrush.referenceAspect or 0
    state.structuralBrushReferencePressurePsi = pressureWheelBrush and pressureWheelBrush.referencePressurePsi or 0
    state.mechanicalResearchAuthority = mechanicalResearchAuthority
    state.targetHotFraction = targetHotFraction
    state.lockRatio = lockRatio
    state.patchFraction = patchFraction

    return state.gripMultiplier, state
end

-- wear -> DRY grip ownership.
--
-- [WG-R1][DIRECT INDUSTRY TEST/TECHNICAL GUIDANCE]
-- Tire Rack documents that ordinary/UHP tyres typically improve dry response as tread
-- gets shallower because tread-block squirm falls; shaved new UHP tyres can be faster
-- at 6/32 and ~4/32 than full depth. This is geometric tread-depth behaviour, NOT a
-- justification for assuming naturally aged rubber never loses grip.
-- https://www.tirerack.com/upgrade-garage/can-tires-be-shaved-for-autocross-track-use-competition
--
-- [WG-R2][REGULATORY / MOTORSPORT TARGET]
-- FIA F1 2025-2027 tyre tender explicitly requests performance life < wear life <
-- durability and says a non-linear performance gradient change ("cliff") at a
-- certain wear percentage is desirable. It does NOT prescribe a universal mu loss.
-- https://legal.fia.com/web/appeloffre.nsf/0F43EC70A0FACADFC1258991006043A9/$FILE/ITT%20F1%20TYRES%202025-2027%20(including%20F2%20and%20F3)_UPDATE%2014.04.2023.pdf?openelement=
--
-- [WG-E1][KTS ENGINEERING DEFAULT]
-- Standard/Sport/Semi and Drift get NO direct dry-mu penalty from uniform tread-depth
-- loss. Their wear still changes physical tread depth, block stiffness/C_alpha, B100,
-- groove geometry, thermal mass/conduction and local wear geometry. Long-term chemical
-- ageing/heat-cycle hardening is a separate future state and must not be faked by depth.
--
-- [WG-E2][KTS RESEARCH-GUIDED RACE CALIBRATION]
-- Generic Race/Slick keeps full dry-mu authority through most of its usable rubber,
-- then receives a late non-linear performance-life cliff. Exact multipliers below are
-- KTS calibration values constrained by [WG-R2], not claimed FIA measured coefficients.
-- Rally road profiles deliberately retain their established wear curve so this
-- road/slick correction does not alter the solved Rally calibration.
M._wearDryGrip = M._wearDryGrip or {}
M._wearDryGrip.legacyConditionDryGrip = function(conditionPercent)
    local c = clamp(finiteNumber(conditionPercent, 100), 0, 100)
    return clamp(0.7701504 + 0.002476352 * c + 0.0001259966 * c ^ 2
        - 0.000002465426 * c ^ 3 + 1.187875e-8 * c ^ 4, 0.02, 1.05)
end
M._wearDryGrip.racePerformancePoints = {
    {0, 0.84}, {5, 0.88}, {15, 0.94}, {25, 0.98},
    {35, 0.995}, {50, 1.00}, {75, 1.00}, {100, 1.00}
}
M._wearDryGrip.raceWearPerformanceGrip = function(conditionPercent)
    local c = clamp(finiteNumber(conditionPercent, 100), 0, 100)
    local points = M._wearDryGrip.racePerformancePoints
    if c <= points[1][1] then return points[1][2] end
    for j = 2, #points do
        local x1, y1 = points[j - 1][1], points[j - 1][2]
        local x2, y2 = points[j][1], points[j][2]
        if c <= x2 then
            return lerp(y1, y2, clamp((c - x1) / math.max(x2 - x1, 1e-9), 0, 1))
        end
    end
    return points[#points][2]
end
M._wearDryGrip.getMultiplier = function(profileInfo, conditionPercent)
    local id = profileInfo and profileInfo.id or "standard"
    local classId = profileInfo and profileInfo.classId or id
    if id == "standard" or classId == "sport" or classId == "semi_slick" or id == "drift" then
        return 1.0, "uniform-road-depth-neutral[WG-R1/WG-E1]"
    end
    if id == "race" then
        return M._wearDryGrip.raceWearPerformanceGrip(conditionPercent), "race-late-performance-cliff[WG-R2/WG-E2]"
    end
    return M._wearDryGrip.legacyConditionDryGrip(conditionPercent), "legacy-rally-road-wear-curve-preserved"
end

CalculateTyreGrip = function(wheelID, loadBias, treadCoef)
    local data = tyreData[wheelID]
    local detectedTyre = getWheelTyreProfile(wheelID)
    local profile = detectedTyre.profile

    if M._rallyDirt.isRallyProfile(profile)
        and M._rallyDirt.surfaces[data.rally_surface_class] then
        local dirtGrip = M._rallyDirt.getMacroGrip(wheelID, data.rally_surface_class)
        tyreGripTable[wheelID] = dirtGrip
        return dirtGrip
    end

    local directSurfaceGrip, directSurfaceGripRealistic, gripActiveTemp, zoneDirectGrip =
        M._tread1D.evaluateDirectSurfaceGrip(data, profile, loadBias, data.contact_zone_weights, false)

    local wearDryGrip, wearDryGripSource = M._wearDryGrip.getMultiplier(profile, data.condition)
    local tyreGrip = wearDryGrip
    data.uniform_wear_dry_grip_multiplier = wearDryGrip
    data.uniform_wear_dry_grip_source = wearDryGripSource

    tyreGrip = tyreGrip * directSurfaceGrip
    data.direct_surface3_grip_multiplier = directSurfaceGrip
    data.direct_surface3_grip_multiplier_realistic = directSurfaceGripRealistic
    data.direct_surface3_temp_c = gripActiveTemp
    data.direct_surface3_zone_grip = zoneDirectGrip

    tyreGripTable[wheelID] = tyreGrip
    return tyreGrip
end

M._thermalPause.ensureWheelData = function(wheelID, wheelRotator)
    local detectedTyre = getWheelTyreProfile(wheelID)
    local profile = detectedTyre.profile
    local target = clamp(tonumber(getWheelPreheatTarget(wheelID)) or ENV_TEMP, -100, 500)
    local data = tyreData[wheelID]

    if type(data) ~= "table" then
        local _, configuredGaugePressurePa, configuredPressureSource = GetConfiguredPressureReferencePa(wheelID)
        data = {
            working_temp = target,
            temp = {target, target, target, target},
            surface_temp = {target, target, target},
            flash_temp = target,
            condition = 100,
            lastTyregrip = 1,
            brakeCooling = RT.baseBrakeCoolings[wheelID],
            tyre_profile = profile.id,
            tyre_profile_label = profile.label,
            tyre_name = detectedTyre.displayName,
            tyre_internal_name = detectedTyre.internalName,
            tyre_profile_source = detectedTyre.source,
            profile_working_temp = profile.workingTemp,
            profile_overheat_start = profile.overheatStart,
            air_temp = ENV_TEMP,
            rim_temp = ENV_TEMP,
            pressure_psi = configuredGaugePressurePa / PSI_TO_PA,
            thermal_pressure_delta_psi = 0,
            thermal_pressure_ratio = 1,
            pressure_source = "initial-config-fallback",
            pressure_reference_psi = configuredGaugePressurePa / PSI_TO_PA,
            pressure_reference_source = configuredPressureSource,
            pressure_update_hz = 1 / math.max(finiteNumber(M._physicalThermal.wheelCavity.thermalUpdateIntervalS, 0.20), 0.05),
            pressure_control_state = "thermal-pause-native-pressure-read-only"
        }
        tyreData[wheelID] = data
    end

    data.working_temp = target
    data.tyre_profile = profile.id
    data.tyre_profile_label = profile.label
    data.tyre_name = detectedTyre.displayName
    data.tyre_internal_name = detectedTyre.internalName
    data.tyre_profile_source = detectedTyre.source
    data.profile_working_temp = profile.workingTemp
    data.profile_overheat_start = profile.overheatStart
    local physical = M._physicalThermal.getPhysicalProfile(profile)
    if M._tread1D and M._tread1D.setPeakGripHoldProfile then
        M._tread1D.setPeakGripHoldProfile(data, target, physical)
    elseif M._tread1D and M._tread1D.setOperatingStartPreheat then
        M._tread1D.setOperatingStartPreheat(data, target, physical)
        M._tread1D.deriveTemps(data, physical)
    else
        data.temp = type(data.temp) == "table" and data.temp or {target, target, target, target}
        data.temp[1], data.temp[2], data.temp[3], data.temp[4] = target, target, target, target
        data.surface_temp = type(data.surface_temp) == "table" and data.surface_temp or {target, target, target}
        data.surface_temp[1], data.surface_temp[2], data.surface_temp[3] = target, target, target
        data.flash_temp = target
        data.air_temp = ENV_TEMP
        data.rim_temp = ENV_TEMP
    end
    data.ground_cooling_delta = 0
    data.distance_last_step = 0
    data.pressure_control_state = "thermal-pause-native-pressure-read-only"
    data.thermal_cache_force_publish = true
    data.b100_slow_cache_dirty = true
    if M._thermalGripCacheByWheel then M._thermalGripCacheByWheel[wheelID] = nil end
    if M._pressureWheelBrush and M._pressureWheelBrush.slowCacheByWheel then
        M._pressureWheelBrush.slowCacheByWheel[wheelID] = nil
    end
    wheelPreheatRevision[wheelID] = preheatRevision

    return data, target
end

M._thermalPause.applyPeakGrip = function()
    local wheelRotators = wheels and wheels.wheelRotators or nil
    if type(wheelRotators) ~= "table" or next(wheelRotators) == nil then
        M._thermalPause.restoreRequested = true
        return 0
    end

    preheatRevision = preheatRevision + 1
    pendingPreheatTargets = {}
    pendingPreheatModes = {}
    rewindSpinupFreeze = {}
    pendingRewindSpinupContext = nil
    activeRewindSpinupRequestId = -1
    wheelFlashGripState = {}

    local applied = 0
    for wheelID, wheelRotator in pairs(wheelRotators) do
        local data = M._thermalPause.ensureWheelData(wheelID, wheelRotator)
        if data then
            local treadCoef = tonumber(wheelRotator.treadCoef) or 1
            local grip = CalculateTyreGrip(wheelID, 0, treadCoef)
            tyreGripTable[wheelID] = grip

            M._gripRefresh.forceWheel(wheelID, grip)
            applied = applied + 1
        end
    end

    M._thermalPause.restoreRequested = false
    M._thermalPause.restoreRevision = (tonumber(M._thermalPause.restoreRevision) or 0) + 1
    return applied
end

M._thermalPause.setActive = function(active)
    if type(active) == "string" then
        local value = string.lower(active)
        active = value == "true" or value == "1" or value == "on" or value == "yes"
    else
        active = active == true or active == 1
    end

    if active then
        if not M._thermalPause.active then
            M._thermalPause.wearBeforePause = tyreWearEnabled == true
        end
        M._thermalPause.active = true
        if M._adaCamberBridge then M._adaCamberBridge.paused = true end
        M._thermalPause.restoreRequested = true
        local applied = M._thermalPause.applyPeakGrip()
        log("I", "luukstyrethermalsandwear", string.format(
            "Thermal simulation PAUSED: peak-grip temperature restored on %d wheels; WEAR preference=%s",
            applied, tostring(M._thermalPause.wearBeforePause == true)
        ))
    else
        if M._thermalPause.active then
            M._thermalPause.active = false
            if M._adaCamberBridge then M._adaCamberBridge.paused = false end
            M._thermalPause.restoreRequested = false
            tyreWearEnabled = M._thermalPause.wearBeforePause == true
            M._camberSurface.cache = {}
            log("I", "luukstyrethermalsandwear", string.format(
                "Thermal simulation RESUMED: WEAR=%s", tostring(tyreWearEnabled)
            ))
        end
    end

    return M._thermalPause.active
end

M._thermalPause.toggle = function()
    return M._thermalPause.setActive(not M._thermalPause.active)
end

local function getWheelDefinitionForRewind(wheelID, wheelRotator)
    local wheelDefs = v and v.data and v.data.wheels or nil
    if type(wheelDefs) ~= "table" then return nil end

    local direct = wheelDefs[wheelID]
    if type(direct) == "table" then return direct end

    local numericID = tonumber(wheelID)
    if numericID ~= nil then
        direct = wheelDefs[numericID]
        if type(direct) == "table" then return direct end
    end

    local targetName = wheelRotator and tostring(wheelRotator.name or "") or ""
    if targetName ~= "" then
        for _, wheelDef in pairs(wheelDefs) do
            if type(wheelDef) == "table" and tostring(wheelDef.name or "") == targetName then
                return wheelDef
            end
        end
    end
    return nil
end

local function getNodeDefinitionByCid(cid)
    local nodesData = v and v.data and v.data.nodes or nil
    if type(nodesData) ~= "table" or cid == nil then return nil end
    local direct = nodesData[cid]
    if type(direct) == "table" and tonumber(direct.cid) == tonumber(cid) then return direct end
    for _, node in pairs(nodesData) do
        if type(node) == "table" and tonumber(node.cid) == tonumber(cid) then return node end
    end
    return nil
end

local function estimatePressureWheelInertia(wheelID, wheelRotator, wheelDef)
    local radius = math.max(finiteNumber(wheelRotator and wheelRotator.radius, finiteNumber(wheelDef and wheelDef.radius, 0.32)), 0.05)
    local inertia = 0
    local treadMass = 0
    local treadCount = 0

    local node1 = wheelRotator and wheelRotator.node1 or wheelDef and wheelDef.node1
    local node2 = wheelRotator and wheelRotator.node2 or wheelDef and wheelDef.node2
    local ok1, p1 = false, nil
    local ok2, p2 = false, nil
    if obj and obj.getNodePosition and node1 ~= nil and node2 ~= nil then
        ok1, p1 = pcall(obj.getNodePosition, obj, node1)
        ok2, p2 = pcall(obj.getNodePosition, obj, node2)
    end

    local axisX, axisY, axisZ = 0, 1, 0
    local midX, midY, midZ = 0, 0, 0
    local axisReady = false
    if ok1 and p1 and ok2 and p2 then
        local dx = finiteNumber(p2.x, 0) - finiteNumber(p1.x, 0)
        local dy = finiteNumber(p2.y, 0) - finiteNumber(p1.y, 0)
        local dz = finiteNumber(p2.z, 0) - finiteNumber(p1.z, 0)
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        if length > 1e-6 then
            axisX, axisY, axisZ = dx / length, dy / length, dz / length
            midX = (finiteNumber(p1.x, 0) + finiteNumber(p2.x, 0)) * 0.5
            midY = (finiteNumber(p1.y, 0) + finiteNumber(p2.y, 0)) * 0.5
            midZ = (finiteNumber(p1.z, 0) + finiteNumber(p2.z, 0)) * 0.5
            axisReady = true
        end
    end

    local treadNodes = wheelDef and wheelDef.treadNodes or nil
    if axisReady and type(treadNodes) == "table" and obj and obj.getNodePosition then
        for _, cid in pairs(treadNodes) do
            local okPos, pos = pcall(obj.getNodePosition, obj, cid)
            if okPos and pos then
                local nodeDef = getNodeDefinitionByCid(cid)
                local mass = math.max(finiteNumber(nodeDef and (nodeDef.nodeWeight or nodeDef.weight), 0), 0)
                if mass > 0 then
                    local rx = finiteNumber(pos.x, 0) - midX
                    local ry = finiteNumber(pos.y, 0) - midY
                    local rz = finiteNumber(pos.z, 0) - midZ
                    local axial = rx * axisX + ry * axisY + rz * axisZ
                    local radialX = rx - axial * axisX
                    local radialY = ry - axial * axisY
                    local radialZ = rz - axial * axisZ
                    local radialSquared = radialX * radialX + radialY * radialY + radialZ * radialZ
                    inertia = inertia + mass * radialSquared
                    treadMass = treadMass + mass
                    treadCount = treadCount + 1
                end
            end
        end
    end

    local numRays = math.max(math.floor(finiteNumber(wheelDef and wheelDef.numRays, treadCount > 0 and treadCount * 0.5 or 10) + 0.5), 1)
    if treadMass <= 0 then
        treadMass = math.max(finiteNumber(wheelDef and wheelDef.tireWeight, 0), 0)
        if treadMass <= 0 then
            treadMass = math.max(finiteNumber(wheelDef and wheelDef.nodeWeight, 0), 0) * numRays * 2
        end
        if treadMass > 0 then inertia = inertia + treadMass * radius * radius end
    end

    local hubMass = math.max(finiteNumber(wheelDef and wheelDef.hubWeight, 0), 0)
    if hubMass <= 0 then
        hubMass = math.max(finiteNumber(wheelDef and wheelDef.hubNodeWeight, 0), 0) * numRays * 2
    end
    local hubRadius = math.max(finiteNumber(wheelDef and wheelDef.hubRadius, radius * 0.58), 0.02)
    if hubMass > 0 then
        inertia = inertia + hubMass * hubRadius * hubRadius
    end

    if inertia <= 0 then
        inertia = 0.5 * 18 * radius * radius
    end
    return clamp(inertia, 0.03, 30), treadMass + hubMass
end

local function isWheelDrivenForRewind(wheelRotator, wheelDef)
    local value = wheelRotator and (wheelRotator.isPropulsed or wheelRotator.propulsed)
    if value == nil and wheelDef then value = wheelDef.isPropulsed or wheelDef.propulsed end
    if value == true then return true end
    local numeric = tonumber(value)
    if numeric ~= nil then return math.abs(numeric) > 0.001 end
    return false
end

local function rewindSpeedFloorSeconds(speedKmh)
    speedKmh = math.max(finiteNumber(speedKmh, 0), 0)
    if speedKmh < REWIND_SPINUP_MIN_SPEED_KMH then return 0 end
    if speedKmh <= 10 then
        return 0.003 + speedKmh * 0.0009
    elseif speedKmh <= 50 then
        return 0.012 + (speedKmh - 10) * 0.0022
    elseif speedKmh <= 100 then
        return 0.100 + (speedKmh - 50) * 0.0010
    end
    return math.min(0.150 + (speedKmh - 100) * 0.00075, 0.350)
end

local function getSavedWheelState(context, wheelID)
    local states = context and context.wheelStates or nil
    if type(states) ~= "table" then return nil end
    return states[wheelID] or states[tonumber(wheelID)] or states[tostring(wheelID)]
end

local function getSavedGripValue(savedGripTable, wheelID)
    if type(savedGripTable) ~= "table" then return 1 end
    return clamp(finiteNumber(savedGripTable[wheelID] or savedGripTable[tonumber(wheelID)] or savedGripTable[tostring(wheelID)], 1), 0.02, 2.0)
end

local function getEngineInertiaForRewind()
    if not powertrain or type(powertrain.getDevice) ~= "function" then return 0, nil end
    local engine = powertrain.getDevice("mainEngine")
    if type(engine) ~= "table" then return 0, nil end
    local inertia = math.max(finiteNumber(engine.inertia, 0), 0)
    inertia = inertia + math.max(finiteNumber(engine.additionalEngineInertia, 0), 0)
    return inertia, engine
end

local function estimateSavedTotalGearRatio(context, savedWheelAV)
    local engineAV = math.abs(finiteNumber(context and context.engineAV, 0))
    savedWheelAV = math.abs(finiteNumber(savedWheelAV, 0))
    if engineAV > 1 and savedWheelAV > 0.5 then
        local inferred = engineAV / savedWheelAV
        if inferred >= 0.5 and inferred <= 60 then return inferred, "snapshot-av" end
    end

    if powertrain and type(powertrain.getDevice) == "function" then
        local gearbox = powertrain.getDevice("gearbox")
        if type(gearbox) == "table" then
            local gearIndex = math.floor(finiteNumber(context and context.savedGearIndex, 0) + 0.5)
            local gearRatio = nil
            if type(gearbox.gearRatios) == "table" then gearRatio = tonumber(gearbox.gearRatios[gearIndex]) end
            gearRatio = math.abs(finiteNumber(gearRatio, gearbox.gearRatio or 0))
            local liveRatio = math.abs(finiteNumber(gearbox.gearRatio, gearRatio))
            local cumulative = math.abs(finiteNumber(gearbox.cumulativeGearRatio, 0))
            if gearRatio > 0.001 then
                if cumulative > 0.001 and liveRatio > 0.001 then
                    return clamp(gearRatio * cumulative / liveRatio, 0.5, 60), "gearbox-cumulative"
                end
                return clamp(gearRatio, 0.5, 60), "gearbox-ratio"
            end
        end
    end
    return 0, "unavailable"
end

local function calculateLoadSensitivityCoefficient(wheelRotator, wheelDef, loadN)
    local noLoadCoef = finiteNumber(wheelRotator and wheelRotator.noLoadCoef, finiteNumber(wheelDef and wheelDef.noLoadCoef, 1))
    local fullLoadCoef = finiteNumber(wheelRotator and wheelRotator.fullLoadCoef, finiteNumber(wheelDef and wheelDef.fullLoadCoef, 1))
    local slope = math.max(finiteNumber(wheelRotator and wheelRotator.loadSensitivitySlope, finiteNumber(wheelDef and wheelDef.loadSensitivitySlope, 0)), 0)
    if slope <= 0 then return 1 end

    local numRays = math.max(finiteNumber(wheelDef and wheelDef.numRays, 10), 4)
    local estimatedLoadedNodes = math.max(numRays * 0.22, 2)
    local loadPerNode = math.max(loadN, 0) / estimatedLoadedNodes
    local lower = math.min(noLoadCoef, fullLoadCoef)
    local upper = math.max(noLoadCoef, fullLoadCoef)
    return clamp(noLoadCoef - loadPerNode * slope, lower, upper)
end

local function getRestoredTyreDataForWheel(wheelID)
    return tyreData[wheelID] or tyreData[tonumber(wheelID)] or tyreData[tostring(wheelID)]
end

local function makeRewindFrozenState(wheelID, savedWheel, savedGripTable, requestId)
    if type(savedWheel) ~= "table" then return nil end
    local savedAV = math.abs(finiteNumber(savedWheel.angularVelocity, 0))
    local radius = math.max(finiteNumber(savedWheel.radius, 0.32), 0.05)
    local speedKmh = savedAV * radius * 3.6
    local floorTime = rewindSpeedFloorSeconds(speedKmh)
    if floorTime <= 0 or savedAV <= 0.1 then return nil end

    local restoredTyreData = getRestoredTyreDataForWheel(wheelID)
    local restoredTemps = type(restoredTyreData) == "table" and restoredTyreData.temp or nil
    local restoredSurface = type(restoredTyreData) == "table" and restoredTyreData.surface_temp or nil
    local initialTime = clamp(math.max(floorTime, REWIND_SPINUP_MIN_HARD_HOLD_SECONDS), 0.003, REWIND_SPINUP_MAX_FREEZE_SECONDS)
    return {
        requestId = requestId,
        provisional = true,
        remaining = initialTime,
        elapsed = 0,
        protectedUpdates = 0,
        hardHoldRemaining = math.min(initialTime, REWIND_SPINUP_MIN_HARD_HOLD_SECONDS),
        targetAV = savedAV * REWIND_SPINUP_TARGET_RATIO,
        savedAV = savedAV,
        savedSpeedKmh = speedKmh,
        loadN = 0,
        currentLoadN = 0,
        usedFallbackLoad = true,
        loadRecalculated = false,
        effectiveMu = getSavedGripValue(savedGripTable, wheelID),
        thermalGrip = getSavedGripValue(savedGripTable, wheelID),
        speedFloor = floorTime,
        radius = radius,
        effectiveInertia = 0.03,
        wheelInertia = 0.03,
        reflectedEngineInertia = 0,
        driven = false,
        gearRatio = 0,
        ratioSource = "pending-wheel-data",
        groundModel = "pending",
        wheelMass = 0,
        releaseArmed = false,
        staleHighLogged = false,
        restoreMode = "unknown",
        frozenTemps = type(restoredTemps) == "table" and {
            finiteNumber(restoredTemps[1], ENV_TEMP),
            finiteNumber(restoredTemps[2], ENV_TEMP),
            finiteNumber(restoredTemps[3], ENV_TEMP),
            finiteNumber(restoredTemps[4], ENV_TEMP)
        } or nil,
        frozenSurfaceTemps = type(restoredSurface) == "table" and {
            finiteNumber(restoredSurface[1], restoredTemps and restoredTemps[1] or ENV_TEMP),
            finiteNumber(restoredSurface[2], restoredTemps and restoredTemps[2] or ENV_TEMP),
            finiteNumber(restoredSurface[3], restoredTemps and restoredTemps[3] or ENV_TEMP)
        } or nil,
        frozenFlashTemp = type(restoredTyreData) == "table" and
            finiteNumber(restoredTyreData.flash_temp, restoredSurface and restoredSurface[2] or ENV_TEMP) or nil,
        frozenAirTemp = type(restoredTyreData) == "table" and
            finiteNumber(restoredTyreData.air_temp, restoredTemps and restoredTemps[4] or ENV_TEMP) or nil,
        frozenRimTemp = type(restoredTyreData) == "table" and
            finiteNumber(restoredTyreData.rim_temp, ENV_TEMP) or nil,
        frozenCondition = type(restoredTyreData) == "table" and
            finiteNumber(restoredTyreData.condition, 100) or nil
    }
end

local function provisionRewindSpinupFreezeImmediately(context, savedGripTable, requestId)
    local armed = 0
    local wheelStates = type(context) == "table" and context.wheelStates or nil
    if type(wheelStates) ~= "table" then return 0 end
    for wheelID, savedWheel in pairs(wheelStates) do
        local key = tonumber(wheelID) or wheelID
        local state = makeRewindFrozenState(key, savedWheel, savedGripTable, requestId)
        if state then
            state.restoreMode = tostring(context.mode or "unknown")
            rewindSpinupFreeze[key] = state
            armed = armed + 1
        end
    end
    return armed
end

local function armRewindSpinupFreeze(context, savedGripTable)
    local requestId = math.floor(finiteNumber(type(context) == "table" and context.restoreRequestId, latestRewindRestoreRequestId + 1))
    local mode = type(context) == "table" and tostring(context.mode or "") or ""

    if requestId < latestRewindRestoreRequestId then
        log("I", "luukstyrethermalsandwear", string.format(
            "Ignored stale tyre freeze request: request=%d latest=%d", requestId, latestRewindRestoreRequestId))
        return
    end

    local isResume = mode == "resume-after-repair" or mode == "resume-normal" or mode == "resume-existing"
    if not isResume then
        latestRewindRestoreRequestId = requestId
        activeRewindSpinupRequestId = -1
        rewindSpinupFreeze = {}
        pendingRewindSpinupContext = nil
        return
    end

    if requestId == activeRewindSpinupRequestId then
        return
    end

    latestRewindRestoreRequestId = requestId
    activeRewindSpinupRequestId = requestId
    rewindSpinupFreeze = {}
    local provisionalCount = provisionRewindSpinupFreezeImmediately(context, savedGripTable, requestId)
    pendingRewindSpinupContext = {
        requestId = requestId,
        context = context,
        savedGripTable = savedGripTable,
        waitElapsed = 0,
        waitLogged = false
    }
    log("I", "luukstyrethermalsandwear", string.format(
        "Rewind tyre spin-up freeze provisionally armed immediately: request=%d mode=%s wheels=%d",
        requestId, mode, provisionalCount
    ))
end

local function initialisePendingRewindSpinupFreeze(dt)
    local pending = pendingRewindSpinupContext
    if type(pending) ~= "table" then return end
    if finiteNumber(pending.requestId, -1) ~= activeRewindSpinupRequestId then
        pendingRewindSpinupContext = nil
        return
    end

    local safeWaitDt = clamp(math.max(finiteNumber(dt, 0), 0), 0, REWIND_SPINUP_MAX_TIMER_STEP_SECONDS)
    pending.waitElapsed = finiteNumber(pending.waitElapsed, 0) + safeWaitDt

    local wheelRotators = wheels and wheels.wheelRotators or nil
    if type(wheelRotators) ~= "table" or next(wheelRotators) == nil then
        if not pending.waitLogged and pending.waitElapsed >= REWIND_SPINUP_PENDING_LOG_SECONDS then
            pending.waitLogged = true
            log("I", "luukstyrethermalsandwear",
                "Rewind tyre spin-up freeze waiting for post-reset wheel data")
        end
        if pending.waitElapsed >= REWIND_SPINUP_PENDING_MAX_SECONDS then
            log("W", "luukstyrethermalsandwear",
                "Rewind tyre spin-up freeze cancelled: wheel data unavailable after reset")
            pendingRewindSpinupContext = nil
        end
        return
    end

    local context = pending.context or {}
    local savedGripTable = pending.savedGripTable or {}
    local drivenCount = 0
    local wheelCount = 0
    for wheelID, wheelRotator in pairs(wheelRotators) do
        wheelCount = wheelCount + 1
        local wheelDef = getWheelDefinitionForRewind(wheelID, wheelRotator)
        if isWheelDrivenForRewind(wheelRotator, wheelDef) then drivenCount = drivenCount + 1 end
    end
    drivenCount = math.max(drivenCount, 1)

    local engineInertia = getEngineInertiaForRewind()
    local savedGearIndex = math.floor(finiteNumber(context.savedGearIndex, 0) + 0.5)
    local savedClutch = finiteNumber(context.clutch, 0)
    local drivetrainCanBeConnected = savedGearIndex ~= 0 and savedClutch < 0.75
    local nominalLoad = math.max((vehicleMass or 1500) * 9.81 / math.max(activeWheelCount or 4, 1), REWIND_SPINUP_MIN_LOAD_N)
    local armedCount = 0

    for wheelID, wheelRotator in pairs(wheelRotators) do
        local savedWheel = getSavedWheelState(context, wheelID)
        local savedAV = math.abs(finiteNumber(savedWheel and savedWheel.angularVelocity, 0))
        local radius = math.max(finiteNumber(savedWheel and savedWheel.radius, finiteNumber(wheelRotator.radius, 0.32)), 0.05)
        local speedKmh = savedAV * radius * 3.6
        local floorTime = rewindSpeedFloorSeconds(speedKmh)

        if floorTime > 0 and savedAV > 0.1 then
            local wheelDef = getWheelDefinitionForRewind(wheelID, wheelRotator)
            local wheelInertia, wheelMass = estimatePressureWheelInertia(wheelID, wheelRotator, wheelDef)
            local driven = isWheelDrivenForRewind(wheelRotator, wheelDef)
            local gearRatio, ratioSource = estimateSavedTotalGearRatio(context, savedAV)
            local reflectedEngineInertia = 0
            if driven and drivetrainCanBeConnected and engineInertia > 0 and gearRatio > 0 then
                reflectedEngineInertia = clamp(engineInertia * gearRatio * gearRatio / drivenCount, 0, 25)
            end

            local currentLoad = math.abs(finiteNumber(wheelRotator.downForceRaw, 0))
            local loadUsed = currentLoad >= REWIND_SPINUP_MIN_LOAD_N and currentLoad or nominalLoad
            local groundModelName, groundModel = GetGroundModelData(wheelRotator.contactMaterialID1)
            local roadFriction = math.max(finiteNumber(groundModel and groundModel.staticFrictionCoefficient, 1), 0.05)
            local tyreFriction = math.max(finiteNumber(wheelRotator.frictionCoef, finiteNumber(wheelDef and wheelDef.frictionCoef, 1)), 0.05)
            local thermalGrip = getSavedGripValue(savedGripTable, wheelID)
            local loadSensitivity = calculateLoadSensitivityCoefficient(wheelRotator, wheelDef, loadUsed)
            local effectiveMu = clamp(roadFriction * tyreFriction * thermalGrip * loadSensitivity, 0.05, 3.0)
            local availableTorque = math.max(effectiveMu * loadUsed * radius * REWIND_SPINUP_TRACTION_EFFICIENCY, 1)
            local targetAV = savedAV * REWIND_SPINUP_TARGET_RATIO
            local liveAV = math.abs(finiteNumber(wheelRotator.angularVelocity, 0))
            local deltaAV = math.max(targetAV - liveAV, 0)
            local effectiveInertia = wheelInertia + reflectedEngineInertia
            local physicsTime = deltaAV * effectiveInertia / availableTorque
            local freezeTime = clamp(math.max(floorTime, physicsTime * 1.10), 0.003, REWIND_SPINUP_MAX_FREEZE_SECONDS)

            local restoredTyreData = getRestoredTyreDataForWheel(wheelID)
            local restoredTemps = type(restoredTyreData) == "table" and restoredTyreData.temp or nil
            local restoredSurface = type(restoredTyreData) == "table" and restoredTyreData.surface_temp or nil
            local existing = rewindSpinupFreeze[wheelID] or {}
            local elapsedAlready = math.max(finiteNumber(existing.elapsed, 0), 0)
            existing.requestId = activeRewindSpinupRequestId
            existing.restoreMode = tostring(context.mode or existing.restoreMode or "unknown")
            existing.provisional = false
            existing.remaining = math.max(finiteNumber(existing.remaining, 0), math.max(freezeTime - elapsedAlready, 0.003))
            existing.elapsed = elapsedAlready
            existing.protectedUpdates = math.max(finiteNumber(existing.protectedUpdates, 0), 0)
            existing.hardHoldRemaining = math.max(
                finiteNumber(existing.hardHoldRemaining, 0),
                math.min(freezeTime, REWIND_SPINUP_MIN_HARD_HOLD_SECONDS)
            )
            existing.targetAV = targetAV
            existing.savedAV = savedAV
            existing.savedSpeedKmh = speedKmh
            existing.loadN = loadUsed
            existing.currentLoadN = currentLoad
            existing.usedFallbackLoad = currentLoad < REWIND_SPINUP_MIN_LOAD_N
            existing.loadRecalculated = false
            existing.effectiveMu = effectiveMu
            existing.thermalGrip = thermalGrip
            existing.speedFloor = floorTime
            existing.radius = radius
            existing.effectiveInertia = effectiveInertia
            existing.wheelInertia = wheelInertia
            existing.reflectedEngineInertia = reflectedEngineInertia
            existing.driven = driven
            existing.gearRatio = gearRatio
            existing.ratioSource = ratioSource
            existing.groundModel = groundModelName
            existing.wheelMass = wheelMass

            existing.releaseArmed = existing.releaseArmed == true or
                liveAV <= math.max(targetAV * REWIND_SPINUP_RELEASE_ARM_RATIO, 0.25)
            existing.staleHighLogged = existing.staleHighLogged == true

            if type(existing.frozenTemps) ~= "table" and type(restoredTemps) == "table" then
                existing.frozenTemps = {
                    finiteNumber(restoredTemps[1], ENV_TEMP),
                    finiteNumber(restoredTemps[2], ENV_TEMP),
                    finiteNumber(restoredTemps[3], ENV_TEMP),
                    finiteNumber(restoredTemps[4], ENV_TEMP)
                }
            end
            if type(existing.frozenSurfaceTemps) ~= "table" and type(restoredSurface) == "table" then
                existing.frozenSurfaceTemps = {
                    finiteNumber(restoredSurface[1], restoredTemps and restoredTemps[1] or ENV_TEMP),
                    finiteNumber(restoredSurface[2], restoredTemps and restoredTemps[2] or ENV_TEMP),
                    finiteNumber(restoredSurface[3], restoredTemps and restoredTemps[3] or ENV_TEMP)
                }
            end
            if existing.frozenFlashTemp == nil and type(restoredTyreData) == "table" then
                existing.frozenFlashTemp = finiteNumber(
                    restoredTyreData.flash_temp,
                    restoredSurface and restoredSurface[2] or (restoredTemps and restoredTemps[2] or ENV_TEMP)
                )
            end
            if existing.frozenAirTemp == nil and type(restoredTyreData) == "table" then
                existing.frozenAirTemp = finiteNumber(
                    restoredTyreData.air_temp,
                    restoredTemps and restoredTemps[4] or ENV_TEMP
                )
            end
            if existing.frozenRimTemp == nil and type(restoredTyreData) == "table" then
                existing.frozenRimTemp = finiteNumber(restoredTyreData.rim_temp, ENV_TEMP)
            end
            if existing.frozenCondition == nil and type(restoredTyreData) == "table" then
                existing.frozenCondition = finiteNumber(restoredTyreData.condition, 100)
            end
            rewindSpinupFreeze[wheelID] = existing
            armedCount = armedCount + 1

            log("I", "luukstyrethermalsandwear", string.format(
                "Rewind tyre spin-up freeze armed wheel=%s speed=%.1fkm/h targetAV=%.2f time=%.3fs physics=%.3fs load=%.0fN currentLoad=%.0fN mu=%.3f Iwheel=%.3f Iengine=%.3f driven=%s ratio=%.3f(%s) surface=%s",
                tostring(wheelRotator.name or wheelID), speedKmh, targetAV, freezeTime, physicsTime,
                loadUsed, currentLoad, effectiveMu, wheelInertia, reflectedEngineInertia,
                tostring(driven), gearRatio, tostring(ratioSource), tostring(groundModelName)
            ))
        end
    end

    if wheelCount > 0 then
        pendingRewindSpinupContext = nil
        log("I", "luukstyrethermalsandwear", string.format(
            "Rewind tyre spin-up freeze initialized after %.3fs: wheels=%d armed=%d",
            finiteNumber(pending.waitElapsed, 0), wheelCount, armedCount
        ))
    end
end

local function enforceRewindSpinupFrozenTyreState(wheelID, state)
    if type(state) ~= "table" then return end
    local data = tyreData[wheelID]
    if type(data) ~= "table" then return end

    local frozenTemps = state.frozenTemps
    if type(frozenTemps) == "table" then
        data.temp = type(data.temp) == "table" and data.temp or {}
        for zone = 1, 4 do
            data.temp[zone] = finiteNumber(frozenTemps[zone], data.temp[zone] or ENV_TEMP)
        end
        data.air_temp = finiteNumber(state.frozenAirTemp, frozenTemps[4])
        data.rim_temp = finiteNumber(state.frozenRimTemp, data.rim_temp or ENV_TEMP)
    end
    local frozenSurfaceTemps = state.frozenSurfaceTemps
    if type(frozenSurfaceTemps) == "table" then
        data.surface_temp = type(data.surface_temp) == "table" and data.surface_temp or {}
        for zone = 1, 3 do
            data.surface_temp[zone] = finiteNumber(
                frozenSurfaceTemps[zone],
                data.surface_temp[zone] or (data.temp and data.temp[zone]) or ENV_TEMP)
        end
    end
    if state.frozenFlashTemp ~= nil then
        local fallbackSurface = type(data.surface_temp) == "table" and
            (data.surface_temp[2] or data.surface_temp[1]) or ENV_TEMP
        data.flash_temp = finiteNumber(state.frozenFlashTemp, fallbackSurface)
    end
    if state.frozenCondition ~= nil then
        data.condition = finiteNumber(state.frozenCondition, data.condition or 100)
    end
    tyreData[wheelID] = data
end

local function updateRewindSpinupFreeze(wheelID, dt, liveAngularVelocity)
    local state = rewindSpinupFreeze[wheelID]
    if type(state) ~= "table" then return false, nil end

    local liveAV = math.abs(finiteNumber(liveAngularVelocity, 0))
    local targetAV = math.max(finiteNumber(state.targetAV, 0), 0.1)
    local releaseArmThreshold = math.max(targetAV * REWIND_SPINUP_RELEASE_ARM_RATIO, 0.25)
    if not state.releaseArmed then
        if liveAV <= releaseArmThreshold then
            state.releaseArmed = true
            log("I", "luukstyrethermalsandwear", string.format(
                "Rewind tyre spin-up freeze speed release armed wheel=%s liveAV=%.2f threshold=%.2f targetAV=%.2f",
                tostring(wheelID), liveAV, releaseArmThreshold, targetAV
            ))
        elseif not state.staleHighLogged then
            state.staleHighLogged = true
            log("I", "luukstyrethermalsandwear", string.format(
                "Rewind tyre spin-up freeze ignoring stale high AV wheel=%s liveAV=%.2f targetAV=%.2f",
                tostring(wheelID), liveAV, targetAV
            ))
        end
    end

    if state.usedFallbackLoad and not state.loadRecalculated then
        local wheelRotator = wheels and wheels.wheelRotators and wheels.wheelRotators[wheelID] or nil
        local currentLoad = math.abs(finiteNumber(wheelRotator and wheelRotator.downForceRaw, 0))
        if currentLoad >= REWIND_SPINUP_MIN_LOAD_N then
            local wheelDef = getWheelDefinitionForRewind(wheelID, wheelRotator)
            local groundModelName, groundModel = GetGroundModelData(wheelRotator and wheelRotator.contactMaterialID1)
            local roadFriction = math.max(finiteNumber(groundModel and groundModel.staticFrictionCoefficient, 1), 0.05)
            local tyreFriction = math.max(finiteNumber(wheelRotator and wheelRotator.frictionCoef, finiteNumber(wheelDef and wheelDef.frictionCoef, 1)), 0.05)
            local loadSensitivity = calculateLoadSensitivityCoefficient(wheelRotator, wheelDef, currentLoad)
            local effectiveMu = clamp(roadFriction * tyreFriction * finiteNumber(state.thermalGrip, 1) * loadSensitivity, 0.05, 3.0)
            local radius = math.max(finiteNumber(state.radius, wheelRotator and wheelRotator.radius or 0.32), 0.05)
            local availableTorque = math.max(effectiveMu * currentLoad * radius * REWIND_SPINUP_TRACTION_EFFICIENCY, 1)
            local deltaAV = math.max(finiteNumber(state.targetAV, 0) - liveAV, 0)
            local physicsTime = deltaAV * math.max(finiteNumber(state.effectiveInertia, 0.03), 0.03) / availableTorque
            local totalTime = clamp(math.max(finiteNumber(state.speedFloor, 0.003), physicsTime * 1.10), 0.003, REWIND_SPINUP_MAX_FREEZE_SECONDS)
            state.remaining = math.max(totalTime - finiteNumber(state.elapsed, 0), 0)
            state.loadN = currentLoad
            state.currentLoadN = currentLoad
            state.effectiveMu = effectiveMu
            state.groundModel = groundModelName
            state.loadRecalculated = true
            log("I", "luukstyrethermalsandwear", string.format(
                "Rewind tyre spin-up freeze recalculated wheel=%s currentLoad=%.0fN mu=%.3f totalTime=%.3fs remaining=%.3fs",
                tostring(wheelID), currentLoad, effectiveMu, totalTime, state.remaining
            ))
        end
    end

    local safeDt = clamp(math.max(finiteNumber(dt, 0), 0), 0, REWIND_SPINUP_MAX_TIMER_STEP_SECONDS)
    state.elapsed = finiteNumber(state.elapsed, 0) + safeDt
    state.remaining = finiteNumber(state.remaining, 0) - safeDt
    state.hardHoldRemaining = math.max(0, finiteNumber(state.hardHoldRemaining, 0) - safeDt)
    state.liveAV = liveAV

    if finiteNumber(state.protectedUpdates, 0) >= 1 and
       state.hardHoldRemaining <= 0 and state.releaseArmed and liveAV >= targetAV then
        log("I", "luukstyrethermalsandwear", string.format(
            "Rewind tyre spin-up freeze released wheel=%s reason=80%%-speed elapsed=%.3fs liveAV=%.2f targetAV=%.2f",
            tostring(wheelID), finiteNumber(state.elapsed, 0), liveAV, targetAV
        ))
        rewindSpinupFreeze[wheelID] = nil
        return false, nil
    end
    if finiteNumber(state.protectedUpdates, 0) >= 1 and state.remaining <= 0 then
        log("I", "luukstyrethermalsandwear", string.format(
            "Rewind tyre spin-up freeze released wheel=%s reason=timeout elapsed=%.3fs liveAV=%.2f targetAV=%.2f",
            tostring(wheelID), state.elapsed, liveAV, finiteNumber(state.targetAV, 0)
        ))
        rewindSpinupFreeze[wheelID] = nil
        return false, nil
    end
    state.protectedUpdates = finiteNumber(state.protectedUpdates, 0) + 1
    return true, state
end

local hudDebugTelemetryEnabled = false
M.setHudDebugTelemetryEnabled = function(enabled)
    hudDebugTelemetryEnabled = enabled == true
    return hudDebugTelemetryEnabled
end

M.getHudDebugTelemetryEnabled = function()
    return hudDebugTelemetryEnabled == true
end

local function updateGFX(dt)
    if not M._trafficSimulation.shouldRun() then return end
    M._liveStiffnessPopGuard.update(dt)
    M._beamStructureTuner.update()
    local structureTuner = M._beamStructureTuner
    structureTuner.geometryHudAccumulatorS = finiteNumber(structureTuner.geometryHudAccumulatorS, 0) + dt
    if structureTuner.geometryHudAccumulatorS >= finiteNumber(structureTuner.geometryHudIntervalS, 0.20) then
        structureTuner.geometryHudAccumulatorS = 0
        structureTuner.sampleGeometry()
    end
    M._adaCamberBridge.beginFrame(dt)
    RT.tyreProfileRetryTimer = RT.tyreProfileRetryTimer - dt
    local shouldRetryDetection = next(RT.wheelTyreProfiles) == nil or
        RT.tyreProfileRetryRemaining > 0 or RT.tyreProfileFallbackCount > 0
    if shouldRetryDetection and RT.tyreProfileRetryTimer <= 0 and
       wheels and next(wheels.wheelRotators or {}) ~= nil then
        local _, fallbackCount = detectTyreProfiles()
        RT.tyreProfileRetryTimer = fallbackCount > 0 and 0.35 or RT.AUTO_PROFILE_RETRY_INTERVAL
        RT.tyreProfileRetryRemaining = math.max(RT.tyreProfileRetryRemaining - RT.AUTO_PROFILE_RETRY_INTERVAL, 0)

    end

    syncEnvironmentTemperatureFromMailbox()
    if RT.brakeDuctSettings[1] == -1 or RT.brakeDuctSettings[2] == -1 or RT.brakeDuctSettings[1] == nil or RT.brakeDuctSettings[2] == nil then
        local mailboxResult = obj:getLastMailbox("tyreWearMailboxDuct")
        if type(mailboxResult) == "string" then
            local tableMailboxResult = deserialize(mailboxResult)
            if tableMailboxResult ~= nil then
                RT.brakeDuctSettings[1] = tonumber(tableMailboxResult[1])
                RT.brakeDuctSettings[2] = tonumber(tableMailboxResult[2])
            end
        end
    end

    local stream = { data = {} }
    local needsFullHudWheelTelemetry = hudDebugTelemetryEnabled == true
    local vehiclePosition = obj:getPosition()
    local vehicleUp = obj:getDirectionVectorUp()
    local vehicleVelocity = obj:getVelocity()
    M._pitStop.update(dt, vehicleVelocity)
    for i, wd in pairs(wheels.wheelRotators) do
        local w = wheelCache[i] or {}
        w.name = wd.name
        w.radius = wd.radius
        w.width = wd.tireWidth
        w.wheelDir = wd.wheelDir
        w.angularVelocity = wd.angularVelocity
        w.lastSlip = wd.lastSlip
        w.lastSideSlip = wd.lastSideSlip
        w.slipEnergy = finiteNumber(wd.slipEnergy, nil)
        w.downForce = wd.downForce
        w.brakeCooling = wd.brakeTypeSurfaceCoolingCoef
        w.contactMaterialID1 = wd.contactMaterialID1
        w.contactMaterialID2 = wd.contactMaterialID2
        w.treadCoef = wd.treadCoef
        w.softnessCoef = wd.softnessCoef
        w.isBroken = wd.isBroken
        w.isTireDeflated = wd.isTireDeflated
        w.downForceRaw = wd.downForceRaw
        w.brakeSurfaceTemperature = wd.brakeSurfaceTemperature or ENV_TEMP
        w.pressureGroup = wd.pressureGroup

        if M._thermalPause.active then
            w.camber = tonumber(w.camber) or 0
            w.camberSurfaceSource = "thermal-pause"
            w.camberSurfaceValid = false
        else
            -- Surface-relative camber.
            -- node1 is outside rim, node2 is inside. Camber is measured against the
            -- ACTUAL nearby contact plane instead of a world-down/absolute reference.
            local vectorUp = vehicleUp
            local localVectNode1 = obj:getNodePosition(wd.node1)
            local localVectNode2 = obj:getNodePosition(wd.node2)
            local axleAxis = localVectNode2 - localVectNode1
            local vectorWheelForward = axleAxis:cross(vectorUp)
            local vectorWheelUp = vectorWheelForward:cross(axleAxis)
            local wheelCenter = vehiclePosition + (localVectNode2 + localVectNode1) / 2

            local surfaceNormal, camberSurfaceSource = M._camberSurface.estimateContactSurfaceNormal(
                i, wd, wheelCenter, axleAxis, vectorWheelForward, vectorWheelUp, dt
            )

            if surfaceNormal then
                local normalDotAxle = clamp(axleAxis:normalized():dot(surfaceNormal:normalized()), -1, 1)
                w.camber = 90 - math.deg(math.acos(normalDotAxle))
                w.camberSurfaceValid = true
            else
                w.camber = tonumber(w.camber) or 0
                w.camberSurfaceValid = false
                camberSurfaceSource = camberSurfaceSource or "no-surface"
            end
            w.camberSurfaceSource = camberSurfaceSource

            --
            local slipNormal = surfaceNormal or vectorUp
            if slipNormal and axleAxis:length() > 1e-6 and slipNormal:length() > 1e-6 then
                local n = slipNormal:normalized()
                local axleDir = axleAxis:normalized()
                local lateralDir = axleDir - n * axleDir:dot(n)
                if lateralDir:length() > 1e-6 then
                    lateralDir = lateralDir:normalized()
                    local rollingDir = lateralDir:cross(n)
                    if rollingDir:length() > 1e-6 then
                        w.slipLateralDirection = lateralDir
                        w.slipRollingDirection = rollingDir:normalized()
                        w.slipNormalDirection = n
                        w.slipFrameSource = surfaceNormal and "wheel-surface" or "wheel-vehicle-up"
                    end
                end
            end
        end
        wheelCache[i] = w
        M._adaCamberBridge.publishWheel(i, wd, w)
    end

    if M._thermalPause.active then
        if M._thermalPause.restoreRequested then M._thermalPause.applyPeakGrip() end
    else
        initialisePendingRewindSpinupFreeze(dt)
    end

    local loadBiasSide = sensors.gx2 / 5
    loadBiasSide = sigmoid(loadBiasSide, 2) * 2 - 1

    local gx = sensors.gx / 9.81
    local gy = sensors.gy / 9.81
    local gz = sensors.gz / 9.81
    local g_horiz = math.sqrt(gx * gx + gy * gy)
    local g_table = { gx = gx, gy = gy, gz = gz, g_horiz = g_horiz }

    local vehicleAirspeed = electrics.values.airflowspeed
    local vehicleGroundSpeed = vehicleVelocity:length()
    local vehicleForwardDirection = obj:getDirectionVector()
    local vehicleLongitudinalSpeed = math.abs(vehicleVelocity:dot(vehicleForwardDirection))

    local wheelWaterStates, anyWaterContact, activeWaterDetectionMode
    if M._thermalPause.active then
        wheelWaterStates, anyWaterContact, activeWaterDetectionMode = {}, false, "thermal-pause"
    else
        if next(wheelWaterNodeCache) == nil and #vehicleWaterNodeCache == 0 then
            BuildWaterNodeCache()
        end
        wheelWaterStates, anyWaterContact, activeWaterDetectionMode = GetWaterContactStates(dt)
    end

    for i = 0, #wheels.wheelRotators do
        local wheel = obj:getWheel(i)
        local wd = wheels.wheelRotators[i]
        if wheel and wd then
            local groundModelName, groundModel = GetGroundModelData(wheelCache[i].contactMaterialID1)
            local secondaryGroundModelName, secondaryGroundModel = GetGroundModelData(wheelCache[i].contactMaterialID2)
            local isGrassSurface = IsGrassSurface(groundModelName) or IsGrassSurface(secondaryGroundModelName)
            local rallySurfaceClass = M._rallyDirt.classifyPair(
                groundModelName, groundModel, secondaryGroundModelName, secondaryGroundModel,
                M._rallyDirt.wheelRouteClass[i] or "road")
            M._rallyDirt.wheelRouteClass[i] = rallySurfaceClass
            wheelCache[i].rallySurfaceClass = rallySurfaceClass
            wheelCache[i].rallySurfaceLabel = M._rallyDirt.surfaces[rallySurfaceClass]
                and M._rallyDirt.surfaces[rallySurfaceClass].label or "Hard road"
            local rallyHardRoadSurface = rallySurfaceClass == "road"
            local isWaterSurface = wheelWaterStates[i] == true

            local staticFrictionCoefficient = groundModel.staticFrictionCoefficient
            local slidingFrictionCoefficient = groundModel.slidingFrictionCoefficient

            local angularVel = math.max(math.abs(wheelCache[i].angularVelocity), vehicleGroundSpeed * 3) * 0.1 *
                (math.max(groundModel.staticFrictionCoefficient - 0.5, 0.1) * 2) ^ 3
            angularVel = math.floor(angularVel * 10) / 10
            local slipEnergy = wheelCache[i].lastSlip * staticFrictionCoefficient * 0.05
            --
            --
            local wheelSurfaceSpeed = math.abs(finiteNumber(wheelCache[i].angularVelocity, 0)) * math.max(finiteNumber(wheelCache[i].radius, 0.33), 0.01)
            local rollingDir = wheelCache[i].slipRollingDirection
            local lateralDir = wheelCache[i].slipLateralDirection
            local wheelGroundLongitudinalSpeed
            local wheelGroundLateralSpeed
            local wheelCenterVelocity = vehicleVelocity
            local wheelVelocitySource = "vehicle-fallback"
            local slipFrameSource = wheelCache[i].slipFrameSource or "vehicle-fallback"

            --
            --
            if wd.node1 ~= nil and wd.node2 ~= nil and obj.getNodeVelocityVectorXYZ then
                local ok1, v1x, v1y, v1z = pcall(obj.getNodeVelocityVectorXYZ, obj, wd.node1)
                local ok2, v2x, v2y, v2z = pcall(obj.getNodeVelocityVectorXYZ, obj, wd.node2)
                if ok1 and ok2 then
                    v1x, v1y, v1z = finiteNumber(v1x, nil), finiteNumber(v1y, nil), finiteNumber(v1z, nil)
                    v2x, v2y, v2z = finiteNumber(v2x, nil), finiteNumber(v2y, nil), finiteNumber(v2z, nil)
                    if v1x ~= nil and v1y ~= nil and v1z ~= nil and
                       v2x ~= nil and v2y ~= nil and v2z ~= nil then
                        wheelCenterVelocity = vec3(
                            (v1x + v2x) * 0.5,
                            (v1y + v2y) * 0.5,
                            (v1z + v2z) * 0.5
                        )
                        wheelVelocitySource = "axle-node-midpoint"
                    else
                        wheelVelocitySource = "vehicle-fallback-invalid-node-velocity"
                    end
                else
                    wheelVelocitySource = "vehicle-fallback-node-velocity-error"
                end
            end

            if rollingDir and lateralDir and rollingDir:length() > 1e-6 and lateralDir:length() > 1e-6 then
                wheelGroundLongitudinalSpeed = math.abs(wheelCenterVelocity:dot(rollingDir))
                wheelCache[i].signedWheelGroundLateralSpeed = wheelCenterVelocity:dot(lateralDir)
                wheelGroundLateralSpeed = math.abs(wheelCache[i].signedWheelGroundLateralSpeed)
            else
                wheelGroundLongitudinalSpeed = vehicleLongitudinalSpeed
                wheelGroundLateralSpeed = math.sqrt(math.max(vehicleGroundSpeed ^ 2 - vehicleLongitudinalSpeed ^ 2, 0))
                wheelCache[i].signedWheelGroundLateralSpeed = wheelGroundLateralSpeed
                wheelVelocitySource = "vehicle-fallback"
            end

            local longitudinalSlipSpeed = math.abs(wheelSurfaceSpeed - wheelGroundLongitudinalSpeed)
            local lateralSlipSpeed = wheelGroundLateralSpeed
            wheelCache[i].signedLongitudinalSlipSpeed = wheelSurfaceSpeed - wheelGroundLongitudinalSpeed
            wheelCache[i].signedLateralSlipSpeed = finiteNumber(
                wheelCache[i].signedWheelGroundLateralSpeed, wheelGroundLateralSpeed)
            local combinedSlipSpeed = clamp(math.sqrt(longitudinalSlipSpeed ^ 2 + lateralSlipSpeed ^ 2), 0, M._physicalThermal.maxSlipSpeed)

            local grossMotionSpeed = math.max(vehicleGroundSpeed, wheelSurfaceSpeed)
            local stationarySlipGate = 1
            if grossMotionSpeed < 0.45 and combinedSlipSpeed < 0.60 then
                stationarySlipGate = clamp((grossMotionSpeed - 0.15) / 0.30, 0, 1)
                longitudinalSlipSpeed = longitudinalSlipSpeed * stationarySlipGate
                lateralSlipSpeed = lateralSlipSpeed * stationarySlipGate
                wheelCache[i].signedLongitudinalSlipSpeed = wheelCache[i].signedLongitudinalSlipSpeed * stationarySlipGate
                wheelCache[i].signedLateralSlipSpeed = wheelCache[i].signedLateralSlipSpeed * stationarySlipGate
                combinedSlipSpeed = clamp(math.sqrt(longitudinalSlipSpeed ^ 2 + lateralSlipSpeed ^ 2), 0, M._physicalThermal.maxSlipSpeed)
            end
            wheelCache[i].stationarySlipGate = stationarySlipGate
            wheelCache[i].slipFrameSource = slipFrameSource
            wheelCache[i].wheelVelocitySource = wheelVelocitySource
            wheelCache[i].wheelGroundLongitudinalSpeed = wheelGroundLongitudinalSpeed
            wheelCache[i].wheelGroundLateralSpeed = wheelGroundLateralSpeed
            wheelCache[i].kinematicSlipAngleDeg = math.deg(math.atan(
                wheelGroundLateralSpeed / math.max(wheelGroundLongitudinalSpeed, 0.001)
            ))
            wheelCache[i].longitudinalSlipSpeed = longitudinalSlipSpeed
            wheelCache[i].lateralSlipSpeed = lateralSlipSpeed
            wheelCache[i].combinedSlipSpeed = combinedSlipSpeed
            local velCoeff = math.min(angularVel / math.max(slipEnergy, 0.001), 1)
            local deformationEnergy = wheelCache[i].downForce * velCoeff
            local load = wheelCache[i].downForceRaw
            -- Brake temp is measured in degrees C, not F
            local brakeTemp = wheelCache[i].brakeSurfaceTemperature
            if not RT.baseBrakeCoolings[i] then
                RT.baseBrakeCoolings[i] = wheelCache[i].brakeCooling
            end

            local treadCoef = 1.0 - wheelCache[i].treadCoef * 0.45
            local softnessCoef = wheelCache[i].softnessCoef
            local signedRoadCamberDeg = wheelCache[i].camber * wheelCache[i].wheelDir
            local wearProfileCamberDeg, wearProfileDepthDeltaMm = CalcWearProfileCamberCorrectionDeg(i, wheelCache[i].width)
            local effectiveTreadCamberDeg = signedRoadCamberDeg - wearProfileCamberDeg
            local loadBias = loadBiasSide * 0.22 + effectiveTreadCamberDeg / 12
            loadBias = sigmoid(loadBias, 50) * 2 - 1
            wheelCache[i].loadBias = loadBias

            local spinupFreezeActive, spinupFreezeState = false, nil
            local pressurePa = GetTyrePressurePa(i)
            if M._thermalPause.active then
                M._thermalPause.ensureWheelData(i, wheels.wheelRotators[i])
            else
                spinupFreezeActive, spinupFreezeState = updateRewindSpinupFreeze(
                    i, dt, wheelCache[i].angularVelocity
                )
                if spinupFreezeActive then
                    enforceRewindSpinupFrozenTyreState(i, spinupFreezeState)
                end
                if not spinupFreezeActive then
                    CalcTyreWear(dt, i, groundModel, loadBias, treadCoef, slipEnergy, load,
                        angularVel, brakeTemp, wheelCache[i].width, vehicleAirspeed, deformationEnergy, g_table,
                        wheelCache[i].name, wheelCache[i].downForceRaw, pressurePa, vehicleGroundSpeed,
                        vehicleLongitudinalSpeed, wheelCache[i].radius, combinedSlipSpeed,
                        longitudinalSlipSpeed, lateralSlipSpeed, isGrassSurface, isWaterSurface)
                end
            end
            if tyreData[i] then
                tyreData[i].pressure_psi = finiteNumber(pressurePa, 0) / PSI_TO_PA
                tyreData[i].pressure_source = "pressureGroup-live-or-fallback"
                tyreData[i].road_camber_deg = signedRoadCamberDeg
                tyreData[i].wear_profile_camber_correction_deg = wearProfileCamberDeg
                tyreData[i].effective_tread_camber_deg = effectiveTreadCamberDeg
                tyreData[i].wear_profile_outer_inner_delta_mm = wearProfileDepthDeltaMm
            end
            wheels.wheelRotators[i].brakeTypeSurfaceCoolingCoef = wheelCache[i].brakeCooling

            if tyreData[i] then
                tyreData[i].rally_surface_class = rallySurfaceClass
                tyreData[i].rally_surface_label = wheelCache[i].rallySurfaceLabel
            end

            local tyreGrip
            local flashGripMultiplier, flashGripState
            if M._thermalPause.active then
                tyreGrip = CalculateTyreGrip(i, 0, treadCoef)
                flashGripState = wheelFlashGripState[i]
                if type(flashGripState) ~= "table" then
                    flashGripState = {
                        hotFraction = 0, gripMultiplier = 1, slipSpeed = 0, surfaceSpeed = 0,
                        refreshRateHz = 0, residenceTimeS = 0, slipDistancePerPassM = 0,
                        memoryX = 0, lockRatio = 1, patchEffectiveTemp = tyreData[i].working_temp,
                        macroCurveGrip = 1,
                        coolSlideFloorRatio = 1, hotSlideFloorRatio = 1, surfaceHeatState = 0,
                        surfaceHeatDrive = 0, surfaceThermalModifier = 1, surfaceSlideRatio = 1
                    }
                    wheelFlashGripState[i] = flashGripState
                end
                flashGripState.hotFraction = 0
                flashGripState.gripMultiplier = 1
                flashGripState.surfaceHeatState = 0
                flashGripState.surfaceHeatDrive = 0
                flashGripState.surfaceThermalModifier = 1
                flashGripState.shortTermSurfaceModifier = 1
                flashGripState.directFastThermalMultiplier = 1
                flashGripState.directSurfaceCellsGripMultiplier = 1
                flashGripState.directSurfaceCellsGripMultiplierRealistic = 1
                flashGripState.surfaceSlideRatio = 1
                flashGripMultiplier = 1
            else
                tyreGrip = CalculateTyreGrip(i, loadBias, treadCoef)
                if spinupFreezeActive then
                    flashGripState = wheelFlashGripState[i]
                    if type(flashGripState) ~= "table" then
                        flashGripState = {
                            hotFraction = 0, gripMultiplier = 1, slipSpeed = 0, surfaceSpeed = 0,
                            refreshRateHz = 0, residenceTimeS = 0, slipDistancePerPassM = 0,
                            memoryX = 0, lockRatio = 1, patchEffectiveTemp = tyreData[i].working_temp,
                            macroCurveGrip = 1,
                            coolSlideFloorRatio = 1, hotSlideFloorRatio = 1, surfaceHeatState = 0,
                            surfaceHeatDrive = 0, surfaceThermalModifier = 1, surfaceSlideRatio = 1
                        }
                        wheelFlashGripState[i] = flashGripState
                    end
                    flashGripMultiplier = clamp(finiteNumber(flashGripState.gripMultiplier, 1),
                        M._flashMemory.minGripMultiplier, 1.05)
                else
                    flashGripMultiplier, flashGripState = UpdateFlashMemoryGrip(
                        i, dt, vehicleGroundSpeed, wheelCache[i].angularVelocity, wheelCache[i].radius,
                        combinedSlipSpeed, longitudinalSlipSpeed, lateralSlipSpeed,
                        loadBias, wheelCache[i].isTireDeflated or wheelCache[i].isBroken,
                        rallyHardRoadSurface
                    )
                end
            end
            local macroWearGrip = clamp(finiteNumber(tyreGrip, 1), 0.02, 2.0)
            local baselineGripUplift, baselineGripUpliftSource = getBaselineGripUplift(i)
            local activeGripProfile = getWheelTyreProfile(i).profile
            local rallyProfileActive = activeGripProfile
                and (activeGripProfile.id == "rally_asphalt" or activeGripProfile.id == "rally_gravel")
            if rallyProfileActive and not rallyHardRoadSurface then
                baselineGripUplift = 1.0
                baselineGripUpliftSource = "rally-native-terrain-handoff"
            end
            local mechanicalGripMultiplier = clamp(
                finiteNumber(flashGripState and flashGripState.mechanicalRemapMultiplier, 1),
                M._flashMemory.minGripMultiplier, M._flashMemory.mechanicalSlipRemapMaxMultiplier)
            local surfaceThermalGripMultiplier = clamp(
                finiteNumber(flashGripState and flashGripState.surfaceThermalModifier, 1),
                M._flashMemory.minGripMultiplier, 1.0)
            local shortTermSurfaceGripMultiplier = clamp(
                finiteNumber(flashGripState and flashGripState.shortTermSurfaceModifier, 1),
                M._flashMemory.minGripMultiplier, 1.0)
            local directFastThermalGripMultiplier = clamp(
                finiteNumber(flashGripState and flashGripState.directFastThermalMultiplier, 1),
                M._flashMemory.minGripMultiplier, 1.0)
            if rallyProfileActive and not rallyHardRoadSurface then
                flashGripMultiplier = M._rallyDirt.getFastGrip(
                    flashGripState, rallySurfaceClass)
                if flashGripState then
                    flashGripState.gripMultiplier = flashGripMultiplier
                    flashGripState.mechanicalRawMultiplier = 1.0
                    flashGripState.mechanicalRemapMultiplier = 1.0
                    flashGripState.mechanicalResearchAuthority = 0.0
                    flashGripState.modelCurveEnabled = false
                    flashGripState.rallyNativeTerrainHandoff = true
                    flashGripState.rallyDirtFastHeatAuthority = finiteNumber(
                        M._rallyDirt.surfaces[rallySurfaceClass]
                            and M._rallyDirt.surfaces[rallySurfaceClass].fastHeatAuthority, 0)
                end
            end
            local flashOnlyMultiplier = 1.0
            local slickCompoundGripMultiplier = M._slickCompounds.getGripMultiplier(i)
            local slickColdRelativeGripMultiplier = M._slickCompounds.getColdRelativeGripScale(
                activeGripProfile, tyreData[i] and tyreData[i].grip_depth_avg_temp or ENV_TEMP)
            local rallyRoadGripMultiplier = M._rallyCompounds.getRoadGripMultiplier(i, rallyHardRoadSurface)
            if rallyProfileActive and not rallyHardRoadSurface then
                directFastThermalGripMultiplier = 1.0
            end
            local slowBaseGripMultiplier = baselineGripUplift * slickCompoundGripMultiplier
                * slickColdRelativeGripMultiplier * rallyRoadGripMultiplier * macroWearGrip
            local totalGripMultiplier = slowBaseGripMultiplier * flashGripMultiplier * directFastThermalGripMultiplier
            tyreGrip = clamp(totalGripMultiplier, 0.02, 2.0)
            tyreGripTable[i] = tyreGrip
            tyreData[i].rally_surface_class = rallySurfaceClass
            tyreData[i].rally_surface_label = wheelCache[i].rallySurfaceLabel
            tyreData[i].rally_surface_router_source = "gfx-contact-pair"
            tyreData[i].rally_road_model_active = rallyProfileActive == true and rallyHardRoadSurface
            tyreData[i].rally_dirt_model_active = rallyProfileActive == true and not rallyHardRoadSurface
            tyreData[i].rally_dirt_fast_multiplier = rallyProfileActive and not rallyHardRoadSurface
                and flashGripMultiplier or 1.0
            tyreData[i].rally_overlay_multiplier = rallyProfileActive and not rallyHardRoadSurface
                and (macroWearGrip * flashGripMultiplier) or totalGripMultiplier

            local isNotDeflated = 1
            if wheelCache[i].isTireDeflated or wheelCache[i].isBroken then isNotDeflated = 0 end

            local temps = {}
            for j = 1, 4 do
                table.insert(temps, math.floor(tyreData[i].temp[j] * 10) / 10)
            end
            local surfaceTemps = {}
            local surfaceSource = tyreData[i].surface_temp or tyreData[i].temp
            for j = 1, 3 do
                table.insert(surfaceTemps, math.floor((surfaceSource[j] or tyreData[i].temp[j] or ENV_TEMP) * 10) / 10)
            end
            local condition = math.floor(tyreData[i].condition * 10) / 10 * isNotDeflated
            if needsFullHudWheelTelemetry then
            table.insert(stream.data, {
                name = wheelCache[i].name,
                tread_coef = treadCoef,
                working_temp = math.floor(tyreData[i].working_temp * 10) / 10,
                temp = temps,
                surface_temp = surfaceTemps,
                surface_avg_temp = math.floor((tyreData[i].surface_avg_temp or TempRingsToAvgTemp(surfaceSource, loadBias)) * 10) / 10,
                bulk_tread_avg_temp = math.floor((tyreData[i].bulk_tread_avg_temp or TempRingsToAvgTemp(tyreData[i].temp, loadBias)) * 10) / 10,
                core_temp = math.floor((tyreData[i].temp[4] or ENV_TEMP) * 10) / 10,
                avg_temp = math.floor(TempRingsToAvgTemp(tyreData[i].temp, loadBias) * 10) / 10,
                condition = math.floor(tyreData[i].condition * 10) / 10 * isNotDeflated,
                sport_physical_stiffness_active = M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].active == true or false,
                sport_stiffness_test_active = M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].testActive == true or false,
                sport_stiffness_mode = M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].mode or "waiting",
                sport_stiffness_structural_temp_c = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].temperatureC or ENV_TEMP)*10+0.5)/10,
                sport_stiffness_ca_factor = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].caFactor or 1)*1000+0.5)/1000,
                sport_stiffness_target_tread_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].targetTreadScale or 1)*1000+0.5)/1000,
                sport_stiffness_applied_tread_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedTreadScale or 1)*1000+0.5)/1000,
                sport_stiffness_applied_precomp_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedPrecompressionScale or 1)*100000+0.5)/100000,
                sport_stiffness_native_epsilon = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].nativeTopologyEpsilon or 0)*1000000+0.5)/1000000,
                sport_stiffness_epsilon_source = M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].epsilonSource or "not-captured",
                sport_stiffness_relative_warm_ca = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].relativeWarmCa or 1)*1000+0.5)/1000,
                sport_stiffness_realistic_ca_factor = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].realisticCaFactor or 1)*1000+0.5)/1000,
                sport_stiffness_structural_working_temp_c = finiteNumber(M._sportPhysicalStiffness.structuralWorkingTempC,60),
                sport_stiffness_tread_damp_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedTreadDampScale or 1)*1000+0.5)/1000,
                sport_stiffness_warm_target_strength = finiteNumber(M._sportPhysicalStiffness.warmCorrectionTargetStrength,1),
                sport_stiffness_aspect_ratio = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].aspectRatio or 0)*1000+0.5)/1000,
                sport_stiffness_width_mm = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].widthM or 0)*100000+0.5)/100,
                sport_stiffness_predicted_pressure_psi = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].predictedPressurePsi or 0)*100+0.5)/100,
                tyreGrip = math.floor(tyreGrip * 1000) / 1000,
                baseline_grip_uplift = math.floor((baselineGripUplift or 1) * 1000) / 1000,
                baseline_grip_uplift_source = baselineGripUpliftSource or "unknown",
                slick_cold_relative_grip_multiplier = math.floor((slickColdRelativeGripMultiplier or 1) * 1000) / 1000,
                slick_compound = M._slickCompounds.getPreset(),
                slick_compound_grip_multiplier = math.floor((slickCompoundGripMultiplier or 1) * 1000) / 1000,
                rally_surface = M._rallyCompounds.getSurfacePreset(),
                rally_compound = M._rallyCompounds.getCompoundPreset(),
                rally_profile_active = rallyProfileActive == true,
                rally_hard_road_surface = rallyHardRoadSurface == true,
                rally_native_terrain_handoff = rallyProfileActive == true and rallyHardRoadSurface ~= true,
                rally_surface_class = tyreData[i].rally_surface_class or "road",
                rally_surface_label = tyreData[i].rally_surface_label or "Hard road",
                rally_surface_model = tyreData[i].rally_surface_model or "road-model-owned-curve",
                rally_surface_router_source = tyreData[i].rally_surface_router_source or "unknown",
                rally_road_model_active = tyreData[i].rally_road_model_active == true,
                rally_dirt_model_active = tyreData[i].rally_dirt_model_active == true,
                rally_native_ground_model_active = true,
                rally_dirt_block_temp_c = math.floor((tyreData[i].rally_dirt_block_temp_c or ENV_TEMP) * 10) / 10,
                rally_dirt_temp_multiplier = math.floor((tyreData[i].rally_dirt_temp_multiplier or 1) * 1000) / 1000,
                rally_dirt_fast_multiplier = math.floor((tyreData[i].rally_dirt_fast_multiplier or 1) * 1000) / 1000,
                rally_dirt_directional_wear_multiplier = math.floor((tyreData[i].rally_dirt_directional_wear_multiplier or 1) * 1000) / 1000,
                rally_overlay_multiplier = math.floor((tyreData[i].rally_overlay_multiplier or 1) * 1000) / 1000,
                rally_block_height_health = math.floor((tyreData[i].rally_block_height_health or 1) * 1000) / 1000,
                rally_block_active_edge_health = math.floor((tyreData[i].rally_block_active_edge_health or 1) * 1000) / 1000,
                rally_block_edge_xp = math.floor((tyreData[i].rally_block_edge_xp or 1) * 1000) / 1000,
                rally_block_edge_xn = math.floor((tyreData[i].rally_block_edge_xn or 1) * 1000) / 1000,
                rally_block_edge_yp = math.floor((tyreData[i].rally_block_edge_yp or 1) * 1000) / 1000,
                rally_block_edge_yn = math.floor((tyreData[i].rally_block_edge_yn or 1) * 1000) / 1000,
                rally_block_edges_by_zone = tyreData[i].rally_block_edges or {},
                rally_block_edge_x_step = tyreData[i].rally_block_edge_x_step or 0,
                rally_block_edge_y_step = tyreData[i].rally_block_edge_y_step or 0,
                rally_block_longitudinal_share = math.floor((tyreData[i].rally_block_longitudinal_share or 0.5) * 1000) / 1000,
                rally_block_lateral_share = math.floor((tyreData[i].rally_block_lateral_share or 0.5) * 1000) / 1000,
                rally_signed_longitudinal_slip_mps = math.floor((wheelCache[i].signedLongitudinalSlipSpeed or 0) * 1000) / 1000,
                rally_signed_lateral_slip_mps = math.floor((wheelCache[i].signedLateralSlipSpeed or 0) * 1000) / 1000,
                rally_dirt_slip_heat_scale = math.floor((tyreData[i].rally_dirt_slip_heat_scale or 1) * 1000) / 1000,
                rally_dirt_flex_heat_scale = math.floor((tyreData[i].rally_dirt_flex_heat_scale or 1) * 1000) / 1000,
                rally_block_height_wear_scale = math.floor((tyreData[i].rally_block_height_wear_scale or 1) * 1000) / 1000,
                rally_block_edge_wear_scale = math.floor((tyreData[i].rally_block_edge_wear_scale or 1) * 1000) / 1000,
                rally_road_grip_multiplier = math.floor((rallyRoadGripMultiplier or 1) * 1000) / 1000,
                macro_wear_grip_multiplier = math.floor((macroWearGrip or 1) * 1000) / 1000,
                uniform_wear_dry_grip_multiplier = math.floor(finiteNumber(tyreData[i].uniform_wear_dry_grip_multiplier, 1) * 1000) / 1000,
                uniform_wear_dry_grip_source = tyreData[i].uniform_wear_dry_grip_source or "unknown",
                mechanical_grip_multiplier = math.floor((mechanicalGripMultiplier or 1) * 1000) / 1000,
                surface_thermal_grip_multiplier = math.floor((surfaceThermalGripMultiplier or 1) * 1000) / 1000,
                flash_only_grip_multiplier = math.floor((flashOnlyMultiplier or 1) * 1000) / 1000,
                total_model_grip_multiplier = math.floor((totalGripMultiplier or tyreGrip or 1) * 1000) / 1000,
                flash_grip_severity = math.floor((flashGripState.hotFraction or 0) * 1000) / 1000,
                flash_grip_multiplier = math.floor((flashGripState.gripMultiplier or 1) * 1000) / 1000,
                flash_grip_locked = (tyreData[i].circumferential_hotspot_contact or 0) > 0.25,
                flash_grip_slip_speed = math.floor((flashGripState.slipSpeed or 0) * 100) / 100,
                flash_grip_surface_speed = math.floor((flashGripState.surfaceSpeed or 0) * 100) / 100,
                flash_grip_lock_ratio = math.floor((flashGripState.lockRatio or 1) * 1000) / 1000,
                flash_grip_longitudinal_share = 1,
                flash_grip_directional_factor = 1,
                patch_hot_fraction = math.floor((flashGripState.hotFraction or 0) * 1000) / 1000,
                patch_effective_temp = math.floor((flashGripState.patchEffectiveTemp or tyreData[i].avg_temp or tyreData[i].working_temp or ENV_TEMP) * 10) / 10,
                patch_macro_curve_grip = math.floor((flashGripState.macroCurveGrip or 1) * 1000) / 1000,
                flash_rise_c = math.floor((flashGripState.flashRiseC or 0) * 10) / 10,
                flash_equivalent_bulk_temp = math.floor((flashGripState.flashEquivalentBulkTemp or tyreData[i].working_temp or ENV_TEMP) * 10) / 10,
                flash_thermal_modifier = math.floor((flashGripState.flashThermalModifier or 1) * 1000) / 1000,
                cool_slide_floor_ratio = math.floor((flashGripState.coolSlideFloorRatio or 1) * 1000) / 1000,
                hot_slide_floor_ratio = math.floor((flashGripState.hotSlideFloorRatio or 1) * 1000) / 1000,
                surface_heat_state = math.floor((flashGripState.surfaceHeatState or 0) * 1000) / 1000,
                surface_grip_temp_c = math.floor((flashGripState.gripDepthTempC or tyreData[i].grip_depth_avg_temp or ENV_TEMP) * 10) / 10,
                physical_surface_temp_c = math.floor((flashGripState.surfaceTempC or tyreData[i].surface_avg_temp or ENV_TEMP) * 10) / 10,
                surface_heat_drive = math.floor((flashGripState.surfaceHeatDrive or 0) * 1000) / 1000,
                surface_thermal_modifier = math.floor((flashGripState.surfaceThermalModifier or 1) * 1000) / 1000,
                short_surface_overload_raw_c = math.floor((flashGripState.shortTermSurfaceOverloadRawC or 0) * 10) / 10,
                short_surface_overload_c = math.floor((flashGripState.shortTermSurfaceOverloadC or 0) * 10) / 10,
                short_surface_overload_state = math.floor((flashGripState.shortTermSurfaceOverloadState or 0) * 1000) / 1000,
                short_surface_grip_multiplier = math.floor((flashGripState.shortTermSurfaceModifier or 1) * 1000) / 1000,
                direct_fast_surface_grip_multiplier = math.floor((flashGripState.directFastThermalMultiplier or 1) * 1000) / 1000,
                direct_surface3_grip_multiplier = math.floor(finiteNumber(tyreData[i].direct_surface3_grip_multiplier, 1) * 1000) / 1000,
                direct_surface3_temp_c = math.floor(finiteNumber(tyreData[i].direct_surface3_temp_c, tyreData[i].grip_depth_avg_temp or ENV_TEMP) * 10 + 0.5) / 10,
                long_term_surface_slide_ratio = math.floor((flashGripState.longTermSurfaceSlideRatio or 1) * 1000) / 1000,
                surface_slide_ratio = math.floor((flashGripState.surfaceSlideRatio or 1) * 1000) / 1000,
                slip_plateau_source = flashGripState.slipPlateauSource or "unknown",
                patch_grip_multiplier = math.floor((flashGripState.gripMultiplier or 1) * 1000) / 1000,
                patch_refresh_hz = math.floor((flashGripState.refreshRateHz or 0) * 10) / 10,
                patch_residence_ms = math.floor((flashGripState.residenceTimeS or 0) * 10000) / 10,
                patch_slip_distance_mm = math.floor((flashGripState.slipDistancePerPassM or 0) * 10000) / 10,
                patch_memory_x = math.floor((flashGripState.memoryX or 0) * 1000) / 1000,
                patch_memory_raw_h = math.floor((flashGripState.rawMemoryHotFraction or 0) * 1000) / 1000,
                kinematic_slip_angle_deg = math.floor((wheelCache[i].kinematicSlipAngleDeg or 0) * 100 + 0.5) / 100,
                wheel_velocity_source = wheelCache[i].wheelVelocitySource or "unknown",
                brush_sigma_x = math.floor((flashGripState.brushSigmaX or 0) * 1000) / 1000,
                brush_sigma_y = math.floor((flashGripState.brushSigmaY or 0) * 1000) / 1000,
                brush_utilization = math.floor((flashGripState.brushUtilization or 0) * 1000) / 1000,
                brush_sliding_length_fraction = math.floor((flashGripState.brushSlidingLengthFraction or 0) * 1000) / 1000,
                brush_sliding_load_fraction = math.floor((flashGripState.brushSlidingLoadFraction or 0) * 1000) / 1000,
                brush_critical_sigma_x = math.floor((flashGripState.brushCriticalSigmaXUsed or M._flashMemory.brushCriticalSigmaX) * 10000) / 10000,
                brush_critical_sigma_y = math.floor((flashGripState.brushCriticalSigmaYUsed or M._flashMemory.brushCriticalSigmaYFallback) * 10000) / 10000,
                brush_critical_angle_deg = math.floor((flashGripState.brushCriticalAngleDeg or 0) * 100 + 0.5) / 100,
                structural_brush_enabled = flashGripState.structuralBrushEnabled == true,
                structural_brush_geometry_valid = flashGripState.structuralBrushGeometryValid == true,
                structural_brush_stiffness_factor = math.floor((flashGripState.structuralBrushStiffnessFactor or 1) * 1000 + 0.5) / 1000,
                structural_brush_jbeam_valid = flashGripState.structuralBrushJbeamValid == true,
                structural_brush_jbeam_factor = math.floor((flashGripState.structuralBrushJbeamFactor or 1) * 1000 + 0.5) / 1000,
                structural_brush_aspect_ratio = math.floor((flashGripState.structuralBrushAspectRatio or 0) * 1000 + 0.5) / 1000,
                structural_brush_sidewall_mm = math.floor((flashGripState.structuralBrushSidewallHeightM or 0) * 100000 + 0.5) / 100,
                structural_brush_width_mm = math.floor((flashGripState.structuralBrushWidthM or 0) * 100000 + 0.5) / 100,
                structural_brush_live_pressure_psi = math.floor((flashGripState.structuralBrushLivePressurePsi or 0) * 100 + 0.5) / 100,
                structural_brush_reference_aspect = math.floor((flashGripState.structuralBrushReferenceAspect or 0) * 1000 + 0.5) / 1000,
                structural_brush_reference_pressure_psi = math.floor((flashGripState.structuralBrushReferencePressurePsi or 0) * 100 + 0.5) / 100,
                structural_brush_thermal_stiffness_factor = math.floor((flashGripState.structuralBrushThermalStiffnessFactor or 1) * 1000 + 0.5) / 1000,
                structural_brush_structural_temp_c = math.floor((flashGripState.structuralBrushStructuralTempC or ENV_TEMP) * 10 + 0.5) / 10,
                structural_b100_core_temp_c = math.floor((tyreData[i].structural_b100_core_temp_c or tyreData[i].temp[4] or ENV_TEMP) * 10 + 0.5) / 10,
                structural_b100_tread_temp_c = math.floor((tyreData[i].structural_b100_tread_temp_c or tyreData[i].bulk_tread_avg_temp or ENV_TEMP) * 10 + 0.5) / 10,
                structural_b100_surface_temp_c = math.floor((tyreData[i].structural_b100_surface_temp_c or tyreData[i].surface_avg_temp or ENV_TEMP) * 10 + 0.5) / 10,
                brush_critical_longitudinal_thermal_scale = math.floor((flashGripState.brushCriticalLongitudinalThermalScale or 1) * 1000) / 1000,
                brush_critical_thermal_scale = math.floor((flashGripState.brushCriticalThermalScale or 1) * 1000) / 1000,
                mechanical_research_authority = math.floor((flashGripState.mechanicalResearchAuthority or 0) * 1000) / 1000,
                brush_target_hot_fraction = math.floor((flashGripState.targetHotFraction or 0) * 1000) / 1000,
                native_dry_ultimate_ratio = math.floor((flashGripState.nativeDryUltimateRatio or 1) * 1000) / 1000,
                native_dry_node_ratio = math.floor((flashGripState.nativeDryNodeRatio or 1) * 1000) / 1000,
                native_dry_patch_ratio = math.floor((flashGripState.nativeDryPatchRatio or 1) * 1000) / 1000,
                native_dry_stribeck_velocity_mps = math.floor((flashGripState.nativeDryStribeckVelocity or 0) * 1000) / 1000,
                native_dry_stribeck_exponent = math.floor((flashGripState.nativeDryStribeckExponent or 1.75) * 1000) / 1000,
                native_dry_tyre_static_coef = math.floor((flashGripState.nativeDryTyreStaticCoef or 1) * 1000) / 1000,
                native_dry_tyre_sliding_coef = math.floor((flashGripState.nativeDryTyreSlidingCoef or 1) * 1000) / 1000,
                native_deembed_multiplier = math.floor((flashGripState.nativeDeembedMultiplier or 1) * 1000) / 1000,
                mechanical_native_ratio = math.floor((flashGripState.mechanicalNativeRatio or 1) * 1000) / 1000,
                mechanical_target_ratio = math.floor((flashGripState.mechanicalTargetRatio or 1) * 1000) / 1000,
                mechanical_raw_multiplier = math.floor((flashGripState.mechanicalRawMultiplier or 1) * 1000) / 1000,
                mechanical_remap_multiplier = math.floor((flashGripState.mechanicalRemapMultiplier or 1) * 1000) / 1000,
                model_curve_enabled = flashGripState.modelCurveEnabled == true,
                model_curve_profile = tostring(flashGripState.modelCurveProfile or "none"),
                model_curve_base_kinetic_ratio = math.floor((flashGripState.modelCurveBaseKineticRatio or 1) * 1000) / 1000,
                model_curve_kinetic_ratio = math.floor((flashGripState.modelCurveKineticRatio or 1) * 1000) / 1000,
                model_curve_velocity_factor = math.floor((flashGripState.modelCurveVelocityFactor or 1) * 1000) / 1000,
                model_curve_velocity_state = math.floor((flashGripState.modelCurveVelocityState or 0) * 1000) / 1000,
                model_curve_history_state = math.floor((flashGripState.modelCurveHistoryState or 0) * 1000) / 1000,
                model_curve_target_patch_ratio = math.floor((flashGripState.modelCurveTargetPatchRatio or 1) * 1000) / 1000,
                model_curve_commanded_patch_ratio = math.floor((flashGripState.modelCurveCommandedPatchRatio or 1) * 1000) / 1000,
                model_curve_base_authority = math.floor((flashGripState.modelCurveBaseAuthority or 0) * 1000) / 1000,
                model_curve_downward_peak_gate = math.floor((flashGripState.modelCurveDownwardPeakGate or 1) * 1000) / 1000,
                model_curve_authority = math.floor((flashGripState.modelCurveAuthority or 0) * 1000) / 1000,
                model_curve_correction_multiplier = math.floor((flashGripState.modelCurveCorrectionMultiplier or 1) * 1000) / 1000,
                flash_target_total_ratio = math.floor((flashGripState.flashTargetTotalRatio or 1) * 1000) / 1000,
                wheel_rotation_phase = tyreData[i].circumferential_rotation_phase or 0,
                surface_hotspot_strength = math.floor((tyreData[i].circumferential_hotspot_strength or 0) * 1000) / 1000,
                surface_hotspot_contact = math.floor((tyreData[i].circumferential_hotspot_contact or 0) * 1000) / 1000,
                surface_coldspot_strength = math.floor((tyreData[i].circumferential_coldspot_strength or 0) * 1000) / 1000,
                surface_coldspot_contact = math.floor((tyreData[i].circumferential_coldspot_contact or 0) * 1000) / 1000,
                circumferential_model = tyreData[i].circumferential_model or "disabled",
                circumferential_feature_count = tyreData[i].circumferential_thermal_feature_count or 0,
                circumferential_wear_feature_count = tyreData[i].circumferential_wear_feature_count or 0,
                circumferential_sweep_turns = math.floor(finiteNumber(tyreData[i].circumferential_sweep_turns, 0) * 10000 + 0.5) / 10000,
                circumferential_average_blend = math.floor(finiteNumber(tyreData[i].circumferential_average_blend, 0) * 1000 + 0.5) / 1000,
                circumferential_resolution_local_fraction = math.floor(finiteNumber(tyreData[i].circumferential_resolution_local_fraction, 0) * 1000 + 0.5) / 1000,
                circumferential_angular_localization = math.floor(finiteNumber(tyreData[i].circumferential_angular_localization, 0) * 1000 + 0.5) / 1000,
                circumferential_rotation_turns_window = math.floor(finiteNumber(tyreData[i].circumferential_rotation_turns_window, 0) * 10000 + 0.5) / 10000,
                circumferential_angular_speed_rad_s = math.floor(finiteNumber(tyreData[i].circumferential_angular_speed_rad_s, 0) * 100 + 0.5) / 100,
                circumferential_wheel_surface_speed_mps = math.floor(finiteNumber(tyreData[i].circumferential_wheel_surface_speed_mps, 0) * 100 + 0.5) / 100,
                circumferential_local_fraction = math.floor(finiteNumber(tyreData[i].circumferential_local_fraction, 0) * 1000 + 0.5) / 1000,
                circumferential_heat_local_fraction = math.floor(finiteNumber(tyreData[i].circumferential_heat_local_fraction, 0) * 1000 + 0.5) / 1000,
                circumferential_contact_surface_temp_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_surface_temp_c, finiteNumber(tyreData[i].surface_avg_temp, ENV_TEMP)) * 10 + 0.5) / 10,
                circumferential_contact_grip_depth_temp_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_grip_depth_temp_c, finiteNumber(tyreData[i].grip_depth_avg_temp, ENV_TEMP)) * 10 + 0.5) / 10,
                circumferential_contact_grip_depth_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_grip_depth_delta_c, 0) * 10 + 0.5) / 10,
                circumferential_local_l1_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[1], 0) * 10 + 0.5) / 10,
                circumferential_local_l2_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[2], 0) * 10 + 0.5) / 10,
                circumferential_local_l3_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[3], 0) * 10 + 0.5) / 10,
                circumferential_local_l4_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[4], 0) * 10 + 0.5) / 10,
                circumferential_local_l1_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_local_layer_energy_j and tyreData[i].circumferential_local_layer_energy_j[1], 0) * 10 + 0.5) / 10,
                circumferential_local_l2_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_local_layer_energy_j and tyreData[i].circumferential_local_layer_energy_j[2], 0) * 10 + 0.5) / 10,
                circumferential_local_l3_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_local_layer_energy_j and tyreData[i].circumferential_local_layer_energy_j[3], 0) * 10 + 0.5) / 10,
                circumferential_local_l4_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_local_layer_energy_j and tyreData[i].circumferential_local_layer_energy_j[4], 0) * 10 + 0.5) / 10,
                circumferential_contact_structural_temp_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_structural_temp_delta_c, 0) * 10 + 0.5) / 10,
                circumferential_contact_tread_stiffness_ratio = math.floor(finiteNumber(tyreData[i].circumferential_contact_tread_stiffness_ratio, 1) * 1000 + 0.5) / 1000,
                circumferential_contact_tread_spring_scale = math.floor(finiteNumber(tyreData[i].circumferential_contact_tread_spring_scale, 1) * 1000 + 0.5) / 1000,
                circumferential_mean_surface_temp_c = math.floor(finiteNumber(tyreData[i].circumferential_mean_surface_temp_c, finiteNumber(tyreData[i].surface_avg_temp, ENV_TEMP)) * 10 + 0.5) / 10,
                circumferential_hotspot_peak_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_hotspot_peak_delta_c, 0) * 10 + 0.5) / 10,
                circumferential_hotspot_contact_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_hotspot_contact_delta_c, 0) * 10 + 0.5) / 10,
                circumferential_hotspot_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_hotspot_energy_j, 0) * 10 + 0.5) / 10,
                circumferential_coldspot_peak_drop_c = math.floor(finiteNumber(tyreData[i].circumferential_coldspot_peak_drop_c, 0) * 10 + 0.5) / 10,
                circumferential_coldspot_contact_drop_c = math.floor(finiteNumber(tyreData[i].circumferential_coldspot_contact_drop_c, 0) * 10 + 0.5) / 10,
                circumferential_coldspot_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_coldspot_energy_j, 0) * 10 + 0.5) / 10,
                circumferential_thermal_abs_energy_j = math.floor(finiteNumber(tyreData[i].circumferential_thermal_abs_energy_j, 0) * 10 + 0.5) / 10,
                circumferential_local_heat_w = math.floor(finiteNumber(tyreData[i].heat_slip_circumferential_local_w, 0) * 10 + 0.5) / 10,
                circumferential_bulk_heat_w = math.floor(finiteNumber(tyreData[i].heat_slip_circumferential_bulk_w, 0) * 10 + 0.5) / 10,
                circumferential_road_cooling_local_fraction = math.floor(finiteNumber(tyreData[i].circumferential_road_cooling_local_fraction, 0) * 1000 + 0.5) / 1000,
                circumferential_road_cooling_bulk_fraction = math.floor(finiteNumber(tyreData[i].circumferential_road_cooling_bulk_fraction, 1) * 1000 + 0.5) / 1000,
                road_cooling_local_base_w = math.floor(finiteNumber(tyreData[i].road_cooling_local_base_w, 0) * 10 + 0.5) / 10,
                road_cooling_bulk_base_w = math.floor(finiteNumber(tyreData[i].road_cooling_bulk_base_w, 0) * 10 + 0.5) / 10,
                road_cooling_local_feature_exchange_w = math.floor(finiteNumber(tyreData[i].road_cooling_local_feature_exchange_w, 0) * 10 + 0.5) / 10,
                road_cooling_total_w = math.floor(finiteNumber(tyreData[i].road_cooling_total_w, 0) * 10 + 0.5) / 10,
                circumferential_contact_remaining_depth_m = tyreData[i].circumferential_contact_remaining_depth_m or {},
                rewind_spinup_freeze = spinupFreezeActive,
                rewind_spinup_freeze_remaining_ms = spinupFreezeState and math.max(0, math.floor((spinupFreezeState.remaining or 0) * 1000 + 0.5)) or 0,
                rewind_spinup_target_av = spinupFreezeState and spinupFreezeState.targetAV or 0,
                rewind_spinup_live_av = spinupFreezeState and spinupFreezeState.liveAV or math.abs(wheelCache[i].angularVelocity or 0),
                tyre_name = tyreData[i].tyre_name or "Unknown tyre",
                tyre_internal_name = tyreData[i].tyre_internal_name or "unknown_tyre",
                tyre_profile = tyreData[i].tyre_profile or "standard",
                tyre_profile_label = tyreData[i].tyre_profile_label or "Standard / road",
                tyre_profile_source = tyreData[i].tyre_profile_source or "fallback",
                profile_working_temp = tyreData[i].profile_working_temp or 60,
                profile_overheat_start = tyreData[i].profile_overheat_start or 90,
                effective_overheat_start = (tyreData[i].profile_overheat_start or 90) +
                    (tyreData[i].working_temp or 60) - (tyreData[i].profile_working_temp or 60),
                load_bias = loadBias,
                contact_material = groundModelName,
                brake_temp = brakeTemp,
                brake_working_temp = 800,
                camber = wheelCache[i].camber * wheelCache[i].wheelDir,
                camber_surface_source = wheelCache[i].camberSurfaceSource or "unknown",
                tyre_pressure_psi = (wheelCache[i].isTireDeflated or wheelCache[i].isBroken)
                    and 0.0 or (math.floor((tyreData[i].pressure_psi or 30) * 10) / 10),
                tyre_thermal_pressure_delta_psi = math.floor((tyreData[i].thermal_pressure_delta_psi or 0) * 1000) / 1000,
                tyre_thermal_pressure_ratio = tyreData[i].thermal_pressure_ratio or 1,
                tyre_thermal_pressure_cumulative_delta_psi = finiteNumber(tyreData[i].thermal_pressure_cumulative_delta_pa, 0) / PSI_TO_PA,
                tyre_thermal_pressure_pending_delta_psi = finiteNumber(tyreData[i].thermal_pressure_pending_delta_pa, 0) / PSI_TO_PA,
                tyre_pressure_source = tyreData[i].pressure_source or "pressureGroup-live-absolute",
                tyre_pressure_reference_psi = math.floor((tyreData[i].pressure_reference_psi or 30) * 10) / 10,
                tread_void_ratio = tyreData[i].tread_void_ratio or 0,
                tread_surface_void_ratio_live = tyreData[i].tread_surface_void_ratio_live or 0,
                tread_surface_land_fraction_live = tyreData[i].tread_surface_land_fraction_live or 1,
                groove_ground_contact_pressure_exponent = tyreData[i].groove_ground_contact_pressure_exponent or 1,
                groove_ground_contact_conductance_scale = tyreData[i].groove_ground_contact_conductance_scale or 1,
                ground_conductance_solid_reference_w_k = tyreData[i].ground_conductance_solid_reference_w_k or 0,
                ground_conductance_groove_adjusted_w_k = tyreData[i].ground_conductance_groove_adjusted_w_k or 0,
                tread_rubber_fill_fraction = tyreData[i].tread_rubber_fill_fraction or 1,
                tread_full_mass_kg = tyreData[i].tread_full_mass_kg or 0,
                tread_effective_mass_kg = tyreData[i].tread_effective_mass_kg or 0,
                tread_thermal_mass_reduction_fraction = tyreData[i].tread_thermal_mass_reduction_fraction or 0,
                groove_active_depth_m = tyreData[i].groove_active_depth_m or 0,
                groove_depth_fraction = tyreData[i].groove_depth_fraction or 0,
                groove_wall_area_m2 = tyreData[i].groove_wall_area_m2 or 0,
                cooling_zone_surface_void_outer = tyreData[i].cooling_zone_surface_void_outer or 0,
                cooling_zone_surface_void_middle = tyreData[i].cooling_zone_surface_void_middle or 0,
                cooling_zone_surface_void_inner = tyreData[i].cooling_zone_surface_void_inner or 0,
                groove_forced_air_share_outer = tyreData[i].groove_forced_air_share_outer or (1/3),
                groove_forced_air_share_middle = tyreData[i].groove_forced_air_share_middle or (1/3),
                groove_forced_air_share_inner = tyreData[i].groove_forced_air_share_inner or (1/3),
                ground_cooling_share_outer = tyreData[i].ground_cooling_share_outer or (1/3),
                ground_cooling_share_middle = tyreData[i].ground_cooling_share_middle or (1/3),
                ground_cooling_share_inner = tyreData[i].ground_cooling_share_inner or (1/3),
                groove_forced_air_speed_mps = tyreData[i].groove_forced_air_speed_mps or 0,
                groove_forced_h_w_m2_k = tyreData[i].groove_forced_h_w_m2_k or 0,
                groove_forced_conductance_w_k = tyreData[i].groove_forced_conductance_w_k or 0,
                groove_forced_cooling_w = tyreData[i].groove_forced_cooling_w or 0,
                thermal_master_hz = tyreData[i].thermal_master_hz or 60,
                thermal_tier_cells_2_3_hz = tyreData[i].thermal_tier_cells_2_3_hz or 30,
                thermal_tier_cells_4_6_hz = tyreData[i].thermal_tier_cells_4_6_hz or 15,
                thermal_tier_cells_7_10_hz = tyreData[i].thermal_tier_cells_7_10_hz or 7.5,
                thermal_tier_cells_11_12_hz = tyreData[i].thermal_tier_cells_11_12_hz or 5,
                thermal_core_hz = tyreData[i].thermal_core_hz or 5,
                active_tread_cells = tyreData[i].tread_active_cell_count or {12,12,12},
                surface_partial_cell_m = tyreData[i].tread_surface_partial_cell_m or {},
                adaptive_tread_mode = tyreData[i].tread_adaptive_mode or {},
                current_cell_rate_hz = tyreData[i].current_cell_rate_hz or {},
                adaptive_start_depth_mm = tyreData[i].adaptive_start_depth_mm or 0,
                adaptive_reference_cell_mm = tyreData[i].adaptive_reference_cell_mm or 0,
                tread_cell_retirements = tyreData[i].tread_cell_retirements or {0,0,0},
                wear_exported_thermal_energy_j = tyreData[i].wear_exported_thermal_energy_j or 0,
                wear_exported_hotspot_energy_j = tyreData[i].wear_exported_hotspot_energy_j or 0,
                virtual_wear_exported_hotspot_energy_j = tyreData[i].virtual_wear_exported_hotspot_energy_j or 0,
                surface_boundary_wear_reset_count = tyreData[i].surface_boundary_wear_reset_count or 0,
                adaptive_remap_energy_error_j = tyreData[i].adaptive_remap_energy_error_j or 0,
                adaptive_hotspot_remap_error_j = tyreData[i].adaptive_hotspot_remap_error_j or 0,
                thermal_pending_core_j = tyreData[i].thermal_pending_core_j or 0,
                thermal_pending_tread_j = tyreData[i].thermal_pending_tread_j or 0,
                thermal_internal_balance_error_j = tyreData[i].thermal_internal_balance_error_j or 0,
                thermal_cache_revision = tyreData[i].thermal_cache_revision or 0,
                thermal_cache_age_ms = tyreData[i].thermal_cache_age_ms or 0,
                tyre_pressure_reference_source = tyreData[i].pressure_reference_source or "fallback-cold-30psi",
                tyre_pressure_reference_temp_c = math.floor((tyreData[i].pressure_reference_temp_c or ENV_TEMP) * 10) / 10,
                tyre_air_temp = math.floor((tyreData[i].air_temp or ENV_TEMP) * 10) / 10,
                tyre_sidewall_outer_temp = math.floor((tyreData[i].sidewall_outer_temp or ENV_TEMP) * 10) / 10,
                tyre_sidewall_inner_temp = math.floor((tyreData[i].sidewall_inner_temp or ENV_TEMP) * 10) / 10,
                tyre_sidewall_outer_heat_share = math.floor(finiteNumber(tyreData[i].heat_roll_sidewall_outer_share, 0.5) * 1000 + 0.5) / 1000,
                tyre_sidewall_inner_heat_share = math.floor(finiteNumber(tyreData[i].heat_roll_sidewall_inner_share, 0.5) * 1000 + 0.5) / 1000,
                tyre_sidewall_outer_source_w = math.floor(finiteNumber(tyreData[i].sidewall_outer_source_w, 0) * 10 + 0.5) / 10,
                tyre_sidewall_inner_source_w = math.floor(finiteNumber(tyreData[i].sidewall_inner_source_w, 0) * 10 + 0.5) / 10,
                tyre_sidewall_semantics = "actual-outer-inner",
                tyre_rim_temp = math.floor((tyreData[i].rim_temp or ENV_TEMP) * 10) / 10,
                preheat_hot_air_target_c = math.floor((tyreData[i].preheat_hot_air_target_c or 0) * 10) / 10,
                preheat_hot_pressure_target_psi = math.floor((tyreData[i].preheat_hot_pressure_target_psi or 0) * 10) / 10,
                cavity_volume_l = math.floor((tyreData[i].cavity_volume_l or 0) * 100) / 100,
                cavity_sealed_air_mass_g = math.floor((tyreData[i].cavity_sealed_air_mass_kg or 0) * 100000) / 100,
                cavity_thermal_update_hz = tyreData[i].cavity_thermal_update_hz or 5,
                cavity_gas_capacity_j_k = math.floor((tyreData[i].cavity_gas_capacity_j_k or 0) * 10) / 10,
                rim_heat_capacity_j_k = math.floor((tyreData[i].rim_heat_capacity_j_k or 0) * 10) / 10,
                rim_external_conductance_w_k = math.floor((tyreData[i].rim_external_conductance_w_k or 0) * 100) / 100,
                sidewall_air_conductance_w_k = math.floor((tyreData[i].sidewall_air_conductance_w_k or 0) * 100) / 100,
                sidewall_external_conductance_w_k = math.floor((tyreData[i].sidewall_external_conductance_w_k or 0) * 100) / 100,
                core_cavity_conductance_w_k = math.floor((tyreData[i].core_cavity_conductance_w_k or 0) * 100) / 100,
                sidewall_heat_capacity_j_k = math.floor((tyreData[i].sidewall_heat_capacity_j_k or 0) * 10) / 10,
                core_heat_capacity_j_k = math.floor((tyreData[i].core_heat_capacity_j_k or 0) * 10) / 10,
                total_structural_heat_capacity_j_k = math.floor((tyreData[i].total_structural_heat_capacity_j_k or tyreData[i].old_lumped_core_heat_capacity_j_k or 0) * 10) / 10,
                tread_cooling_width_factor = math.floor((tyreData[i].tread_cooling_width_factor or 1) * 1000) / 1000,
                tread_cooling_area_m2 = math.floor((tyreData[i].tread_cooling_area_m2 or 0) * 10000) / 10000,
                tread_air_exposed_area_m2 = math.floor((tyreData[i].tread_air_exposed_area_m2 or 0) * 10000) / 10000,
                sidewall_external_area_m2 = math.floor((tyreData[i].sidewall_external_area_m2 or 0) * 10000) / 10000,
                rim_air_conductance_w_k = math.floor((tyreData[i].rim_air_conductance_w_k or 0) * 100) / 100,
                cavity_peristaltic_flow_fraction = math.floor((tyreData[i].cavity_peristaltic_flow_fraction or 0) * 10000) / 10000,
                cavity_peristaltic_air_speed_mps = math.floor((tyreData[i].cavity_peristaltic_air_speed_mps or 0) * 100) / 100,
                cavity_deformation_pump_factor = math.floor((tyreData[i].cavity_deformation_pump_factor or 0) * 1000) / 1000,
                rim_airflow_mps = math.floor((tyreData[i].rim_airflow_mps or 0) * 100) / 100,
                pressure_control_state = tyreData[i].pressure_control_state or "initialising",
                pressure_update_hz = tyreData[i].pressure_update_hz or (1 / math.max(finiteNumber(M._physicalThermal.wheelCavity.thermalUpdateIntervalS, 0.20), 0.05)),
                contact_patch_m2 = tyreData[i].contact_patch_m2 or 0,
                contact_patch_ratio = tyreData[i].contact_patch_ratio or 0,
                contact_patch_length_m = tyreData[i].contact_patch_length_m or 0,
                wear_model = tyreData[i].wear_model or "legacy",
                wear_model_k1 = math.floor((tyreData[i].wear_model_k1 or 0) * 10000 + 0.5) / 10000,
                wear_model_k2 = math.floor((tyreData[i].wear_model_k2 or 0) * 10000 + 0.5) / 10000,
                wear_model_local_slip_factor = math.floor((tyreData[i].wear_model_local_slip_factor or 0) * 1000 + 0.5) / 1000,
                wear_model_local_slip_mps = math.floor((tyreData[i].wear_model_local_slip_speed_mps or 0) * 1000 + 0.5) / 1000,
                wear_model_abrasion_sliding_scale = math.floor((tyreData[i].wear_model_abrasion_sliding_scale or 1) * 1000 + 0.5) / 1000,
                wear_model_sliding_fraction = math.floor((tyreData[i].wear_model_sliding_fraction or 0) * 1000 + 0.5) / 1000,
                wear_model_contact_duty = math.floor((tyreData[i].wear_model_contact_duty or 0) * 10000 + 0.5) / 10000,
                wear_model_effective_temp_c = math.floor((tyreData[i].wear_model_effective_temp_c or ENV_TEMP) * 10 + 0.5) / 10,
                wear_model_surface_authority = math.floor((tyreData[i].wear_model_surface_authority or 0) * 1000 + 0.5) / 1000,
                wear_model_temp_multiplier = math.floor((tyreData[i].wear_model_temp_multiplier or 0) * 1000 + 0.5) / 1000,
                wear_model_contact_pressure_mpa = math.floor((tyreData[i].wear_model_contact_pressure_mpa or 0) * 1000 + 0.5) / 1000,
                wear_model_depth_step_mm = tyreData[i].wear_model_depth_step_mm or 0,
                tyre_width_m = tyreData[i].tyre_width_m or 0,
                tyre_radius_m = tyreData[i].tyre_radius_m or 0,
                ground_contact_factor = tyreData[i].ground_contact_factor or 0,
                ground_cooling_delta = tyreData[i].ground_cooling_delta or 0,
                is_grass_surface = tyreData[i].is_grass_surface or false,
                is_water_surface = tyreData[i].is_water_surface or false,
                water_cooling_multiplier = tyreData[i].water_cooling_multiplier or 1,
                surface_slip_heat_rate = tyreData[i].surface_slip_heat_rate or TEMP_SLIP_GAIN_RATE,
                surface_ground_cooling_percent = tyreData[i].surface_ground_cooling_percent or 100,
                flash_temp = math.floor((tyreData[i].flash_temp or tyreData[i].temp[1] or ENV_TEMP) * 10) / 10,
                physical_slip_speed_mps = math.floor((tyreData[i].slip_speed_mps or 0) * 100) / 100,
                slip_longitudinal_mps = math.floor((wheelCache[i].longitudinalSlipSpeed or 0) * 100) / 100,
                slip_lateral_mps = math.floor((wheelCache[i].lateralSlipSpeed or 0) * 100) / 100,
                wheel_ground_longitudinal_mps = math.floor((wheelCache[i].wheelGroundLongitudinalSpeed or 0) * 100) / 100,
                wheel_ground_lateral_mps = math.floor((wheelCache[i].wheelGroundLateralSpeed or 0) * 100) / 100,
                wheel_normal_load_n = math.floor(math.max(
                    finiteNumber(wheelCache[i].downForceRaw, wheelCache[i].downForce or 0), 0) + 0.5),
                beamng_last_slip = math.floor(finiteNumber(wheelCache[i].lastSlip, 0) * 1000 + 0.5) / 1000,
                beamng_last_side_slip = math.floor(finiteNumber(wheelCache[i].lastSideSlip, 0) * 1000 + 0.5) / 1000,
                slip_frame_source = wheelCache[i].slipFrameSource or "unknown",
                stationary_slip_gate = wheelCache[i].stationarySlipGate or 1,
                road_patch_temp = math.floor((tyreData[i].road_patch_temp or ROAD_TEMP) * 10) / 10,
                road_refresh_rate_hz = tyreData[i].road_refresh_rate_hz or 0,
                tread_area_m2 = tyreData[i].tread_area_m2 or 0,
                exposed_area_m2 = tyreData[i].exposed_area_m2 or 0,
                thin_surface_heat_capacity_j_k = tyreData[i].thin_surface_heat_capacity_j_k or 0,
                skin_heat_capacity_j_k = tyreData[i].skin_heat_capacity_j_k or 0,
                core_heat_capacity_j_k = tyreData[i].core_heat_capacity_j_k or 0,
                tread_cell_count = tyreData[i].tread_cell_count or 0,
                tread_nominal_depth_mm = (tyreData[i].tread_nominal_depth_m or 0) * 1000,
                tread_remaining_depth_mm = (tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                tread_remaining_outer_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[1] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                tread_remaining_middle_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[2] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                tread_remaining_inner_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[3] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                tread_nonwearable_reserve_mm = (tyreData[i].tread_nonwearable_reserve_m or 0) * 1000,
                tread_wearable_remaining_mm = (tyreData[i].tread_wearable_remaining_m or 0) * 1000,
                tread_field_outer = tyreData[i].tread_field and tyreData[i].tread_field[1] or nil,
                tread_field_middle = tyreData[i].tread_field and tyreData[i].tread_field[2] or nil,
                tread_field_inner = tyreData[i].tread_field and tyreData[i].tread_field[3] or nil,
                road_camber_deg = tyreData[i].road_camber_deg or 0,
                wear_profile_camber_correction_deg = tyreData[i].wear_profile_camber_correction_deg or 0,
                effective_tread_camber_deg = tyreData[i].effective_tread_camber_deg or 0,
                wear_profile_outer_inner_delta_mm = tyreData[i].wear_profile_outer_inner_delta_mm or 0,
                grip_depth_avg_temp = tyreData[i].grip_depth_avg_temp or 0,
                thermal_effective_local_slip_speed_mps = tyreData[i].thermal_effective_local_slip_speed_mps or 0,
                virtual_regenerated_depth_mm = (tyreData[i].virtual_regenerated_depth_m or 0) * 1000,
                thermal_brush_utilization = tyreData[i].thermal_brush_utilization or 0,
                thermal_sliding_load_fraction = tyreData[i].thermal_sliding_load_fraction or 0,
                flash_excitation_w = tyreData[i].flash_excitation_w or 0,
                flash_to_surface_w = tyreData[i].flash_to_surface_w or 0,
                heat_roll_mechanical_loss_w = tyreData[i].heat_roll_mechanical_loss_w or 0,
                heat_roll_retained_fraction = tyreData[i].heat_roll_retained_fraction or 1,
                heat_roll_w = tyreData[i].heat_roll_w or 0,
                heat_roll_tread_w = tyreData[i].heat_roll_tread_w or 0,
                heat_roll_sidewall_w = tyreData[i].heat_roll_sidewall_w or 0,
                heat_roll_core_w = tyreData[i].heat_roll_core_w or 0,
                heat_roll_tread_share = tyreData[i].heat_roll_tread_share or 0.40,
                heat_deformation_w = tyreData[i].heat_deformation_w or 0,
                heat_deformation_tread_w = tyreData[i].heat_deformation_tread_w or 0,
                heat_deformation_sidewall_w = tyreData[i].heat_deformation_sidewall_w or 0,
                heat_deformation_core_w = tyreData[i].heat_deformation_core_w or 0,
                heat_deformation_sidewall_outer_w = tyreData[i].heat_deformation_sidewall_outer_w or 0,
                heat_deformation_sidewall_inner_w = tyreData[i].heat_deformation_sidewall_inner_w or 0,
                heat_extra_flex_hysteresis_fraction = tyreData[i].heat_extra_flex_hysteresis_fraction or 0,
                heat_true_sliding_fraction = tyreData[i].heat_true_sliding_fraction or 0,
                heat_adhesion_deformation_fraction = tyreData[i].heat_adhesion_deformation_fraction or 1,
                heat_brush_mechanical_w = tyreData[i].heat_brush_mechanical_w or 0,
                heat_brush_longitudinal_mechanical_w = tyreData[i].heat_brush_longitudinal_mechanical_w or 0,
                heat_brush_lateral_mechanical_w = tyreData[i].heat_brush_lateral_mechanical_w or 0,
                heat_sliding_mechanical_w = tyreData[i].heat_sliding_mechanical_w or 0,
                heat_wear_depth_ratio = tyreData[i].heat_wear_depth_ratio or 1,
                heat_wear_depth_volume_factor = tyreData[i].heat_wear_depth_volume_factor or 1,
                heat_wear_depth_rolling_scale = tyreData[i].heat_wear_depth_rolling_scale or 1,
                heat_wear_depth_longitudinal_scale = tyreData[i].heat_wear_depth_longitudinal_scale or 1,
                heat_wear_depth_lateral_scale = tyreData[i].heat_wear_depth_lateral_scale or 1,
                heat_deformation_longitudinal_w = tyreData[i].heat_deformation_longitudinal_w or 0,
                heat_deformation_lateral_w = tyreData[i].heat_deformation_lateral_w or 0,
                contact_zone_outer = tyreData[i].contact_zone_weights and tyreData[i].contact_zone_weights[1] or (1 / 3),
                contact_zone_middle = tyreData[i].contact_zone_weights and tyreData[i].contact_zone_weights[2] or (1 / 3),
                contact_zone_inner = tyreData[i].contact_zone_weights and tyreData[i].contact_zone_weights[3] or (1 / 3),
                flex_heat_zone_outer = tyreData[i].flex_heat_zone_weights and tyreData[i].flex_heat_zone_weights[1] or (1 / 3),
                flex_heat_zone_middle = tyreData[i].flex_heat_zone_weights and tyreData[i].flex_heat_zone_weights[2] or (1 / 3),
                flex_heat_zone_inner = tyreData[i].flex_heat_zone_weights and tyreData[i].flex_heat_zone_weights[3] or (1 / 3),
                cross_tread_reference_pressure_psi = tyreData[i].cross_tread_reference_pressure_psi or 0,
                cross_tread_reference_pressure_source = tyreData[i].cross_tread_reference_pressure_source or "profile-fallback",
                cross_tread_deflection_index = tyreData[i].cross_tread_deflection_index or 1,
                cross_tread_shoulder_center_ratio = tyreData[i].cross_tread_shoulder_center_ratio or 1,
                cross_tread_flex_shoulder_center_ratio = tyreData[i].cross_tread_flex_shoulder_center_ratio or 1,
                cross_tread_compliance = tyreData[i].cross_tread_compliance or 1,
                cross_tread_effective_compliance = tyreData[i].cross_tread_effective_compliance or 1,
                cross_tread_raw_load_ratio = tyreData[i].cross_tread_raw_load_ratio or 1,
                cross_tread_effective_load_ratio = tyreData[i].cross_tread_effective_load_ratio or 1,
                cross_tread_raw_pressure_ratio = tyreData[i].cross_tread_raw_pressure_ratio or 1,
                cross_tread_effective_pressure_ratio = tyreData[i].cross_tread_effective_pressure_ratio or 1,
                cross_tread_crown_support_ratio = tyreData[i].cross_tread_crown_support_ratio or 0,
                cross_tread_crown_load_authority = tyreData[i].cross_tread_crown_load_authority or 1,
                cross_tread_crown_pressure_authority = tyreData[i].cross_tread_crown_pressure_authority or 1,
                cross_tread_crown_flex_authority = tyreData[i].cross_tread_crown_flex_authority or 1,
                cross_tread_lateral_demand = tyreData[i].cross_tread_lateral_demand or 0,
                cross_tread_flex_strain_proxy = tyreData[i].cross_tread_flex_strain_proxy or 0,
                cross_tread_lateral_hysteresis_gain = tyreData[i].cross_tread_lateral_hysteresis_gain or 1,
                heat_slip_raw_w = tyreData[i].heat_slip_raw_w or 0,
                heat_slip_gross_retained_w = tyreData[i].heat_slip_gross_retained_w or 0,
                heat_slip_stored_w = tyreData[i].heat_slip_stored_w or 0,
                heat_destruction_energy_demand_w = tyreData[i].heat_destruction_energy_demand_w or 0,
                heat_destruction_energy_sink_w = tyreData[i].heat_destruction_energy_sink_w or 0,
                heat_destruction_energy_limited_by_gross = tyreData[i].heat_destruction_energy_limited_by_gross == true,
                heat_destruction_activation = tyreData[i].heat_destruction_activation or 0,
                heat_destruction_predicted_flash_c = tyreData[i].heat_destruction_predicted_flash_c or 0,
                heat_destruction_removed_mass_kg_step = tyreData[i].heat_destruction_removed_mass_kg_step or 0,
                heat_destruction_activated_mass_kg_step = tyreData[i].heat_destruction_activated_mass_kg_step or 0,
                post_wear_contact_thermal_refresh_count = tyreData[i].post_wear_contact_thermal_refresh_count or 0,
                heat_interface_mu = tyreData[i].heat_interface_mu or 0,
                heat_native_node_ratio = tyreData[i].heat_native_node_ratio or 1,
                heat_native_ultimate_ratio = tyreData[i].heat_native_ultimate_ratio or 1,
                heat_applied_grip_scale = tyreData[i].heat_applied_grip_scale or 1,
                heat_slip_distance_per_pass_m = tyreData[i].heat_slip_distance_per_pass_m or 0,
                heat_surface_localization = tyreData[i].heat_surface_localization or 1,
                heat_flash_localization = tyreData[i].heat_flash_localization or 1,
                brake_to_rim_heat_w = tyreData[i].brake_to_rim_heat_w or 0,
                brake_to_rim_conductance_w_k = tyreData[i].brake_to_rim_conductance_w_k or 0,
                cool_skin_air_w = tyreData[i].cool_skin_air_w or 0,
                cool_ground_w = tyreData[i].cool_ground_w or 0,
                cool_sliding_w = tyreData[i].cool_sliding_w or 0,
                cool_radiation_w = tyreData[i].cool_radiation_w or 0,
                cool_degradation_w = tyreData[i].cool_degradation_w or 0,
                hot_acceptance = tyreData[i].hot_acceptance or 1,
                brush_dynamic_fiala = tyreData[i].structural_brush_dynamic_fiala == true,
                brush_load_ratio = tyreData[i].structural_brush_load_ratio or 1,
                brush_load_shape = tyreData[i].structural_brush_load_shape or 1,
                brush_wear_stiffness_factor = tyreData[i].structural_brush_wear_stiffness_factor or 1,
                brush_thermal_stiffness_factor = tyreData[i].structural_brush_thermal_stiffness_factor or 1,
                brush_structural_temp_c = tyreData[i].structural_brush_structural_temp_c or ENV_TEMP,
                brush_mu_thermal_scale = tyreData[i].structural_brush_mu_thermal_scale or 1,
            })
            else
                table.insert(stream.data, {
                    name = wheelCache[i].name,
                    working_temp = math.floor(tyreData[i].working_temp * 10) / 10,
                    temp = temps,
                    surface_temp = surfaceTemps,
                    condition = condition,
                    camber = wheelCache[i].camber * wheelCache[i].wheelDir,
                    load_bias = loadBias,
                    avg_temp = math.floor(TempRingsToAvgTemp(tyreData[i].temp, loadBias) * 10) / 10,
                    flash_temp = math.floor((tyreData[i].flash_temp or tyreData[i].temp[1] or ENV_TEMP) * 10) / 10,
                    tyre_air_temp = math.floor((tyreData[i].air_temp or ENV_TEMP) * 10) / 10,
                    tyre_rim_temp = math.floor((tyreData[i].rim_temp or ENV_TEMP) * 10) / 10,
                    tyre_sidewall_outer_temp = math.floor((tyreData[i].sidewall_outer_temp or ENV_TEMP) * 10) / 10,
                    tyre_sidewall_inner_temp = math.floor((tyreData[i].sidewall_inner_temp or ENV_TEMP) * 10) / 10,
                    tyre_pressure_psi = (wheelCache[i].isTireDeflated or wheelCache[i].isBroken)
                        and 0.0 or (math.floor((tyreData[i].pressure_psi or 30) * 10) / 10),
                    tyre_pressure_reference_psi = math.floor((tyreData[i].pressure_reference_psi or 30) * 10) / 10,
                    preheat_hot_pressure_target_psi = math.floor((tyreData[i].preheat_hot_pressure_target_psi or 0) * 10) / 10,
                    patch_hot_fraction = math.floor((flashGripState.hotFraction or 0) * 1000) / 1000,
                    patch_effective_temp = math.floor((flashGripState.patchEffectiveTemp or tyreData[i].avg_temp or tyreData[i].working_temp or ENV_TEMP) * 10) / 10,
                    surface_hotspot_contact = math.floor((tyreData[i].circumferential_hotspot_contact or 0) * 1000) / 1000,
                    patch_grip_multiplier = math.floor((flashGripState.gripMultiplier or 1) * 1000) / 1000,
                    brush_sliding_length_fraction = math.floor((flashGripState.brushSlidingLengthFraction or 0) * 1000) / 1000,
                    native_dry_patch_ratio = math.floor((flashGripState.nativeDryPatchRatio or 1) * 1000) / 1000,
                    flash_thermal_modifier = math.floor((flashGripState.flashThermalModifier or 1) * 1000) / 1000,
                    kinematic_slip_angle_deg = math.floor((wheelCache[i].kinematicSlipAngleDeg or 0) * 100 + 0.5) / 100,
                    brush_critical_angle_deg = math.floor((flashGripState.brushCriticalAngleDeg or 0) * 100 + 0.5) / 100,
                    tread_nominal_depth_mm = (tyreData[i].tread_nominal_depth_m or 0) * 1000,
                    tread_remaining_depth_mm = (tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                    tread_nonwearable_reserve_mm = (tyreData[i].tread_nonwearable_reserve_m or 0) * 1000,
                    tread_wearable_remaining_mm = (tyreData[i].tread_wearable_remaining_m or 0) * 1000,
                    tread_remaining_outer_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[1] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                    tread_remaining_middle_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[2] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                    tread_remaining_inner_mm = (tyreData[i].tread_remaining_depth_m and tyreData[i].tread_remaining_depth_m[3] or tyreData[i].tread_mean_remaining_depth_m or 0) * 1000,
                    tread_field_outer = tyreData[i].tread_field and tyreData[i].tread_field[1] or nil,
                    tread_field_middle = tyreData[i].tread_field and tyreData[i].tread_field[2] or nil,
                    tread_field_inner = tyreData[i].tread_field and tyreData[i].tread_field[3] or nil,
                    circumferential_local_l1_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[1], 0) * 10 + 0.5) / 10,
                    circumferential_local_l2_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[2], 0) * 10 + 0.5) / 10,
                    circumferential_local_l3_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[3], 0) * 10 + 0.5) / 10,
                    circumferential_local_l4_delta_c = math.floor(finiteNumber(tyreData[i].circumferential_contact_layer_delta_c and tyreData[i].circumferential_contact_layer_delta_c[4], 0) * 10 + 0.5) / 10,
                    baseline_grip_uplift = math.floor((baselineGripUplift or 1) * 1000) / 1000,
                    baseline_grip_uplift_source = baselineGripUpliftSource or "unknown",
                    cross_tread_reference_pressure_psi = tyreData[i].cross_tread_reference_pressure_psi or 0,
                    cross_tread_reference_pressure_source = tyreData[i].cross_tread_reference_pressure_source or "profile-fallback",
                    profile_overheat_start = tyreData[i].profile_overheat_start or 90,
                    effective_overheat_start = (tyreData[i].profile_overheat_start or 90) +
                        (tyreData[i].working_temp or 60) - (tyreData[i].profile_working_temp or 60),
                    pressure_control_state = tyreData[i].pressure_control_state or "initialising",
                    tyre_name = tyreData[i].tyre_name or "Unknown tyre",
                    tyre_internal_name = tyreData[i].tyre_internal_name or "unknown_tyre",
                    tyre_profile = tyreData[i].tyre_profile or "standard",
                    tyre_profile_label = tyreData[i].tyre_profile_label or "Standard / road",
                    tyre_profile_source = tyreData[i].tyre_profile_source or "fallback",
                    sport_physical_stiffness_active = M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].active == true or false,
                    sport_stiffness_applied_tread_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedTreadScale or 1)*1000+0.5)/1000,
                    sport_stiffness_tread_damp_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedTreadDampScale or 1)*1000+0.5)/1000,
                    sport_stiffness_applied_precomp_scale = math.floor((M._sportPhysicalStiffness.wheelState[i] and M._sportPhysicalStiffness.wheelState[i].appliedPrecompressionScale or 1)*100000+0.5)/100000,
                })
            end
            if not M._thermalPause.active and tyreWearEnabled and condition <= 0.05 then
                beamstate.deflateTire(i)
            end

            M._gripRefresh.setTarget(i, tyreGrip, dt)
        end
    end
    M._sportPhysicalStiffness.update(dt)
    if not M._thermalPause.active then
        totalTimeMod60 = (totalTimeMod60 + dt) % 60
    end
    stream.total_time_mod_60 = totalTimeMod60
    stream.wear_enabled = tyreWearEnabled
    stream.grip_refresh_min_hz = M._gripRefresh.minimumHz
    stream.grip_refresh_physics_seen = M._gripRefresh.physicsSeen == true
    stream.grip_refresh_last_gfx_hz = 1 / math.max(M._gripRefresh.lastGfxDt or (1 / 60), 0.001)
    stream.thermals_paused = M._thermalPause.active == true
    stream.repeated_test_thermal_cap_enabled = M._repeatedTestThermalCap.enabled == true
    stream.arcade_handling_mode_enabled = RT.arcadeHandlingEnabled == true
    stream.arcade_handling_mode_revision = RT.arcadeHandlingRevision or 0
    stream.arcade_handling_mode_last_command = RT.arcadeHandlingLastCommand or "NONE"
    stream.arcade_thermal_penalty_severity = M._arcadeHandling.thermalPenaltySeverity
    stream.arcade_thermal_stiffness_severity = M._arcadeHandling.thermalStiffnessSeverity
    stream.arcade_physical_stiffness_severity = M._arcadeHandling.physicalStiffnessSeverity
    stream.arcade_physical_working_temp_c = M._arcadeHandling.physicalWorkingTempC
    stream.arcade_physical_working_blend_span_c = M._arcadeHandling.physicalWorkingBlendSpanC
    stream.thermal_pause_restore_revision = M._thermalPause.restoreRevision or 0
    stream.sport_physical_stiffness = M._sportPhysicalStiffness.getSummary()
    stream.locked_patch_flash_grip_enabled = RT.lockedPatchFlashGripEnabled
    stream.flash_memory_grip_enabled = RT.lockedPatchFlashGripEnabled
    stream.flash_memory_model = "v1.4-rally-preview-peak-gate-slip-speed-gravel-groove-exclusive-road-dirt-directional-block-wear-12cell-fiala-60hz"
    stream.brush_critical_sigma_x = M._flashMemory.brushCriticalSigmaX
    local streamBrushTable = M._flashMemory.brushCriticalSigmaYByProfile
    stream.brush_standard_full_slide_deg = math.deg(math.atan(streamBrushTable.standard))
    stream.brush_sport_full_slide_deg = math.deg(math.atan(streamBrushTable.sport))
    stream.brush_race_full_slide_deg = math.deg(math.atan(streamBrushTable.race))
    stream.brush_rally_asphalt_full_slide_deg = math.deg(math.atan(streamBrushTable.rally_asphalt))
    stream.brush_rally_gravel_full_slide_deg = math.deg(math.atan(streamBrushTable.rally_gravel))
    stream.brush_drift_full_slide_deg = math.deg(math.atan(streamBrushTable.drift))
    stream.brush_research_onset_b = M._flashMemory.mechanicalResearchOnsetB
    stream.brush_research_full_b = M._flashMemory.mechanicalResearchFullB
    stream.pressurewheel_brush_enabled = M._pressureWheelBrush.enabled == true
    stream.pressurewheel_brush_strength = M._pressureWheelBrush.strength
    stream.pressurewheel_sidewall_exponent = M._pressureWheelBrush.sidewallAspectExponent
    stream.pressurewheel_aspect_geometry_model = M._pressureWheelBrush.aspectGeometryModel or "hewson-relative-v2-nominal-metric-size"
    stream.pressurewheel_pressure_exponent = M._pressureWheelBrush.livePressureExponent
    stream.pressurewheel_width_exponent = M._pressureWheelBrush.widthExponent
    stream.pressurewheel_jbeam_influence = M._pressureWheelBrush.jbeamStructureInfluence
    stream.cross_tread_research_enabled = M._crossTreadResearch.enabled == true
    stream.cross_tread_pressure_shape_gain = M._crossTreadResearch.pressureShapeGain
    stream.cross_tread_pressure_exponent = M._crossTreadResearch.pressureRatioExponent
    stream.cross_tread_load_exponent = M._crossTreadResearch.loadRatioExponent
    stream.cross_tread_flex_edge_gain = M._crossTreadResearch.flexEdgeGain
    stream.cross_tread_flex_compliance_exponent = M._crossTreadResearch.flexComplianceExponent
    stream.cross_tread_crown_support_sport = M._crossTreadResearch.crownSupportRatioByProfile.sport
    stream.cross_tread_crown_support_race = M._crossTreadResearch.crownSupportRatioByProfile.race
    stream.cross_tread_crown_support_rally_asphalt = M._crossTreadResearch.crownSupportRatioByProfile.rally_asphalt
    stream.cross_tread_crown_support_rally_gravel = M._crossTreadResearch.crownSupportRatioByProfile.rally_gravel
    stream.native_stribeck_deembed_enabled = M._flashMemory.nativeStribeckDeembedEnabled == true
    stream.flash_micro_temp_sensitivity = M._flashMemory.flashLocalToBulkEquivalentScale
    stream.direct_flash_grip_enabled = false
    stream.short_surface_overload_enabled = M._slipPlateau.shortTermSurfaceOverloadEnabled == true
    stream.short_surface_rise_tau_ms = M._slipPlateau.shortTermRiseTauS * 1000
    stream.short_surface_release_tau_ms = M._slipPlateau.shortTermReleaseTauS * 1000
    local referenceAsphalt = groundModels and (groundModels.ASPHALT or groundModels.asphalt) or nil
    stream.native_reference_asphalt_static = finiteNumber(referenceAsphalt and referenceAsphalt.staticFrictionCoefficient, M._flashMemory.nativeStribeckFallbackStaticMu)
    stream.native_reference_asphalt_sliding = finiteNumber(referenceAsphalt and referenceAsphalt.slidingFrictionCoefficient, M._flashMemory.nativeStribeckFallbackSlidingMu)
    stream.native_reference_asphalt_stribeck_velocity = finiteNumber(referenceAsphalt and referenceAsphalt.stribeckVelocity, M._flashMemory.nativeStribeckFallbackVelocityMps)
    stream.any_water_contact = anyWaterContact
    stream.water_detection_mode = activeWaterDetectionMode
    stream.water_cooling_multiplier = WATER_COOLING_MULTIPLIER
    do
        local activeProfile = TYRE_PROFILES.standard
        if wheels and wheels.wheelRotatorCount and wheels.wheelRotatorCount > 0 then
            local detectedActive = getWheelTyreProfile(0)
            if detectedActive and detectedActive.profile then activeProfile = detectedActive.profile end
        elseif MANUAL_TYRE_PROFILE ~= "auto" and MANUAL_TYRE_PROFILE ~= "rally" and TYRE_PROFILES[MANUAL_TYRE_PROFILE] then
            activeProfile = TYRE_PROFILES[MANUAL_TYRE_PROFILE]
        end
        local activePhysical = M._physicalThermal.getPhysicalProfile(activeProfile)
        local activeMaterial = M._physicalThermal.getEffectiveTreadMaterial(activeProfile)
        local volumetric = activeMaterial.density * activeMaterial.cp
        local diffusivity = activeMaterial.conductivity / math.max(volumetric, 1) * 1e6
        stream.active_thermal_material = {
            enabled = true,
            profile_id = activeProfile.id or "standard",
            class_id = activeProfile.classId or activeProfile.id or "standard",
            label = activeProfile.label or "Standard / road",
            material_source = activeMaterial.source,
            provenance = activeMaterial.provenance,
            confidence = activeMaterial.confidence,
            conductivity_w_mk = activeMaterial.conductivity,
            density_kg_m3 = activeMaterial.density,
            cp_j_kgk = activeMaterial.cp,
            volumetric_heat_capacity_j_m3k = volumetric,
            diffusivity_mm2_s = diffusivity,
            tread_depth_mm = finiteNumber(activePhysical.treadDepthM, 0.006) * 1000,
            skin_core_conductance_w_k = finiteNumber(activePhysical.skinCoreConductance, 0),
            slip_heat_partition = finiteNumber(activePhysical.slipHeatPartition, 0),
            deformation_scale = finiteNumber(activePhysical.deformationScale, 1),
            tread_void_ratio = finiteNumber(activePhysical.treadVoidRatio, 0),
        }
    end
    stream.tuning_values = getTuningValues()
    stream.tuning_native_values = getTuningNativeValues()
    local advancedProfileKey, advancedProfileSource, advancedProfileMixed = M._physicalThermal.getAdvancedProfileKey()
    stream.advanced_profile_key = advancedProfileKey
    stream.advanced_profile_source = advancedProfileSource
    stream.advanced_profile_mixed = advancedProfileMixed == true
    stream.advanced_profile_read_only = MANUAL_TYRE_PROFILE == "auto"
    stream.structure_tuner_stats = {
        cached = M._beamStructureTuner.stats.cached or 0,
        applied = M._beamStructureTuner.stats.applied or 0,
        failed = M._beamStructureTuner.stats.failed or 0,
        ref_applied = M._beamStructureTuner.stats.refApplied or 0,
        ref_failed = M._beamStructureTuner.stats.refFailed or 0,
        skipped = M._beamStructureTuner.stats.skippedDeflated or 0,
        side = M._beamStructureTuner.stats.side or 0,
        tread = M._beamStructureTuner.stats.tread or 0,
        reinf = M._beamStructureTuner.stats.reinf or 0,
        wheels = M._beamStructureTuner.stats.wheelCount or 0,
        endpoint_resolved = M._beamStructureTuner.stats.endpointResolved or 0,
        endpoint_missing = M._beamStructureTuner.stats.endpointMissing or 0,
        revision = M._beamStructureTuner.revision or 0,
        status = M._beamStructureTuner.stats.lastError or "unknown",
        side_precompression_scale = M._beamStructureTuner.multipliers.sidePrecompression or 1,
        tread_precompression_scale = M._beamStructureTuner.multipliers.treadPrecompression or 1,
        reinf_precompression_scale = M._beamStructureTuner.multipliers.reinfPrecompression or 1,
        geometry = M._beamStructureTuner.getGeometryTelemetry(true),
    }
    stream.pit_racing_mode_enabled = M._pitStop.enabled == true
    stream.pit_stop_state = M._pitStop.state or "off"
    stream.pit_stop_message = M._pitStop.message or "PIT MANAGER"
    stream.pit_stop_progress = clamp(finiteNumber(M._pitStop.progress, 0), 0, 1)
    stream.pit_stop_remaining_s = math.max(finiteNumber(M._pitStop.remainingS, 0), 0)
    stream.pit_stop_duration_s = math.max(finiteNumber(M._pitStop.durationS, 15), 0.001)
    stream.pit_stop_vehicle_speed_kmh = math.max(finiteNumber(M._pitStop.lastSpeedKmh, 0), 0)
    stream.pit_stop_staged_profile = M._pitStop.stagedProfile or MANUAL_TYRE_PROFILE
    stream.pit_stop_staged_slick_compound = M._pitStop.stagedSlickCompound or M._slickCompounds.getPreset()
    stream.pit_stop_staged_rally_surface = M._pitStop.stagedRallySurface or M._rallyCompounds.getSurfacePreset()
    stream.pit_stop_staged_rally_compound = M._pitStop.stagedRallyCompound or M._rallyCompounds.getCompoundPreset()
    stream.preheat_default_target_c = M._pitStop.getDefaultPreheatTarget()
    stream.pit_stop_staged_preheat_mode = normalisePreheatMode(M._pitStop.stagedPreheatMode)
    stream.pit_stop_staged_preheat_target_c = tonumber(M._pitStop.stagedPreheatTargetC) or stream.preheat_default_target_c
    local stagedCornerTargets = M._advancedPreheat.normaliseTargets(M._pitStop.stagedPreheatCornerTargets)
    stream.pit_stop_staged_preheat_advanced = stagedCornerTargets ~= nil
    stream.pit_stop_staged_preheat_fl_c = stagedCornerTargets and stagedCornerTargets.FL or nil
    stream.pit_stop_staged_preheat_fr_c = stagedCornerTargets and stagedCornerTargets.FR or nil
    stream.pit_stop_staged_preheat_rl_c = stagedCornerTargets and stagedCornerTargets.RL or nil
    stream.pit_stop_staged_preheat_rr_c = stagedCornerTargets and stagedCornerTargets.RR or nil
    M._axlePressureOverride.captureInitialTune(false)
    if M._pitStop.stagedFrontPsi == nil then M._pitStop.stagedFrontPsi = M._axlePressureOverride.frontPsi end
    if M._pitStop.stagedRearPsi == nil then M._pitStop.stagedRearPsi = M._axlePressureOverride.rearPsi end
    stream.tyre_pressure_tuned_front_psi = M._axlePressureOverride.initialFrontPsi
    stream.tyre_pressure_tuned_rear_psi = M._axlePressureOverride.initialRearPsi
    stream.pit_stop_staged_front_psi = M._pitStop.stagedFrontPsi
    stream.pit_stop_staged_rear_psi = M._pitStop.stagedRearPsi
    stream.tyre_pressure_override_front_psi = M._axlePressureOverride.frontPsi
    stream.tyre_pressure_override_rear_psi = M._axlePressureOverride.rearPsi
    stream.tyre_pressure_live_front_psi = M._axlePressureOverride.getLiveAverage("front")
    stream.tyre_pressure_live_rear_psi = M._axlePressureOverride.getLiveAverage("rear")
    stream.pit_stop_throttle_locked = M._pitStop.throttleLocked == true
    stream.tyre_profile_preset = MANUAL_TYRE_PROFILE
    stream.slick_compound_preset = M._slickCompounds.getPreset()
    local activeSlickCompound = M._slickCompounds.getSelected()
    stream.slick_compound_grip_multiplier = activeSlickCompound and activeSlickCompound.gripMultiplier or 1.0
    stream.slick_compound_wear_multiplier = activeSlickCompound and activeSlickCompound.wearMultiplier or 1.0
    stream.rally_surface_preset = M._rallyCompounds.getSurfacePreset()
    stream.rally_compound_preset = M._rallyCompounds.getCompoundPreset()
    local activeRallyCompound, activeRallySurface = M._rallyCompounds.getSelected()
    stream.rally_profile_id = activeRallySurface and activeRallySurface.profileId or "rally_asphalt"
    stream.rally_road_peak_multiplier = activeRallySurface and activeRallySurface.roadPeakMultiplier or 1.0
    stream.rally_compound_grip_multiplier = activeRallyCompound and activeRallyCompound.gripMultiplier or 1.0
    stream.rally_compound_wear_multiplier = activeRallyCompound and activeRallyCompound.wearMultiplier or 1.0
    stream.rally_dirt_model_version = M._rallyDirt.modelVersion
    stream.rally_surface_router = "physics-first-tick-entry-gfx-full-solve"
    stream.rally_surface_route_changes = M._rallyDirt.physicsRouteChanges
    stream.rally_road_dirt_overlays_mutually_exclusive = true
    stream.rally_native_ground_model_always_active = true
    stream.rally_compound_peak_multiplier = 1.0
    stream.rally_dirt_working_window_low_c = M._rallyDirt.getCompoundWindow()[1]
    stream.rally_dirt_working_window_high_c = M._rallyDirt.getCompoundWindow()[2]
    stream.thermal_preset = ACTIVE_THERMAL_PRESET
    stream.thermal_preset_label = (THERMAL_PRESETS[ACTIVE_THERMAL_PRESET] or THERMAL_PRESETS.general).label
    stream.tyre_profile_detection_revision = RT.tyreProfileDetectionRevision
    stream.tyre_profile_fallback_count = RT.tyreProfileFallbackCount
    stream.tyre_preheat_revision = preheatRevision
    stream.tyre_air_equals_core = false
    stream.pressure_update_hz = 1 / math.max(finiteNumber(M._physicalThermal.wheelCavity.thermalUpdateIntervalS, 0.20), 0.05)
    stream.pressure_ownership = "beamng-native; KTS applies cavity-temperature delta only"
    stream.pressure_hud_read_only = true
    stream.pressure_min_psi = MIN_DYNAMIC_PRESSURE_PSI
    stream.pressure_setter_available = pressureSetterAvailable
    stream.ambient_pressure_pa = ambientPressurePa
    stream.ambient_temp_c = ENV_TEMP
    stream.road_baseline_temp_c = ROAD_TEMP
    stream.road_temp_offset_c = ROAD_TEMP_OFFSET_C
    stream.environment_temp_source = "BeamNG obj:getEnvTemperature() at fresh tyre init; GE core_environment mailbox every 30 s thereafter"
    stream.debug_telemetry_enabled = hudDebugTelemetryEnabled == true

    gui.send("TyreWearThermals", stream)
end

local function getVehicleMass()
    local vehicleMassCache = 0
    for _, n in pairs(v.data.nodes or {}) do
      vehicleMassCache = vehicleMassCache + n.nodeWeight
    end
  return vehicleMassCache
end

local function resetPressureState()
    M._camberSurface.cache = {}
    if M._adaCamberBridge then M._adaCamberBridge.reset() end
    rewindSpinupFreeze = {}
    pendingRewindSpinupContext = nil
    activeRewindSpinupRequestId = -1
    wheelPressureReferenceCache = {}
    wheelFlashGripState = {}
    M._thermalGripCacheByWheel = {}
    if M._pressureWheelBrush then M._pressureWheelBrush.slowCacheByWheel = {} end
    pressureSetterAvailable = nil
    ambientPressurePa = STANDARD_ATMOSPHERIC_PRESSURE_PA
    M._rallyDirt.materialClassCache = {}
    M._rallyDirt.resetRoutes()
end

local function onReset()
    M._pitStop.reset()
    M._userPreferences.load()
    local preservedPhysicsResetEpsilon=M._sportPhysicalStiffness.capturePhysicsResetEpsilon()
    M._beamStructureTuner.resetCache()
    M._sportPhysicalStiffness.resetRuntime()
    vehicleMass = getVehicleMass()
    activeWheelCount = 0
    for _, _ in pairs(wheels.wheelRotators or {}) do
        activeWheelCount = activeWheelCount + 1
    end
    if activeWheelCount < 1 then activeWheelCount = 4 end
    if v ~= nil and v.data ~= nil and v.data.wheels ~= nil then
        tyre_init_data = v.data.wheels
    end
    tyreData = {}
    M._gripRefresh.reset()
    resetPreheatState()
    resetPressureState()
    if M._thermalPause.active then M._thermalPause.restoreRequested = true end
    BuildWaterNodeCache()
    RT.brakeDuctSettings = { -1, -1 }
    detectTyreProfiles()
    M._liveStiffnessPopGuard.arm("vehicle-reset")
    M._axlePressureOverride.applyAll("vehicle-reset")
    M._sportPhysicalStiffness.restorePhysicsResetEpsilon(preservedPhysicsResetEpsilon)
    armTyreProfileDetectionRetry()

    obj:queueGameEngineLua("if luukstyrethermalsandwear then luukstyrethermalsandwear.getGroundModels() end")
end

local function onInit()
    M._trafficSimulation.syncFromMailbox()
    M._pitStop.reset()
    M._userPreferences.load()
    M._beamStructureTuner.resetCache()
    M._sportPhysicalStiffness.resetRuntime()
    tyreData = {}
    M._gripRefresh.reset()
    resetPreheatState()
    resetPressureState()
    BuildWaterNodeCache()
    detectTyreProfiles()
    M._liveStiffnessPopGuard.arm("vehicle-init")
    local tunedFrontPsi, tunedRearPsi = M._axlePressureOverride.captureInitialTune(true)
    M._axlePressureOverride.frontPsi = tunedFrontPsi
    M._axlePressureOverride.rearPsi = tunedRearPsi
    M._pitStop.copyAppliedSelectionToStage()
    armTyreProfileDetectionRetry()
    obj:queueGameEngineLua("if createbrakeductsliders and createbrakeductsliders.sendEnvironmentTemperature then createbrakeductsliders.sendEnvironmentTemperature() end")
    obj:queueGameEngineLua("if luukstyrethermalsandwear then luukstyrethermalsandwear.getGroundModels() end")
end

local function onSettingsChanged()
    M._userPreferences.load()
    RT.brakeDuctSettings = { -1, -1 }
    obj:queueGameEngineLua("if createbrakeductsliders and createbrakeductsliders.sendEnvironmentTemperature then createbrakeductsliders.sendEnvironmentTemperature() end")
end

local function onVehicleSpawned()
end

local function cloneSerializable(value, fallback)
    local seen = {}

    local function clone(item, depth)
        local itemType = type(item)
        if itemType == "number" then
            if item ~= item or item == math.huge or item == -math.huge then return 0 end
            return item
        end
        if itemType == "string" or itemType == "boolean" then return item end
        if itemType ~= "table" then return nil end
        if depth > 32 then return nil end
        if seen[item] then return nil end

        local copy = {}
        seen[item] = copy
        for key, child in pairs(item) do
            local keyType = type(key)
            if keyType == "number" or keyType == "string" or keyType == "boolean" then
                local clonedChild = clone(child, depth + 1)
                if clonedChild ~= nil then copy[key] = clonedChild end
            end
        end
        seen[item] = nil
        return copy
    end

    local result = clone(value, 0)
    if result == nil then return fallback end
    return result
end

M._careerWearPersistence = M._careerWearPersistence or {
    schema = 2,
    pending = nil,
    applied = {},
}

M._careerWearPersistence.capture = function()
    local out = {schema = M._careerWearPersistence.schema, wheels = {}}
    for wheelID, data in pairs(tyreData or {}) do
        if type(data) == "table" then
            local detected = getWheelTyreProfile(wheelID)
            local profile = detected and detected.profile or TYRE_PROFILES.standard
            local physical = M._physicalThermal.getPhysicalProfile(profile)
            local nominal = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
            local reserve = getNonWearableTreadReserveM(nominal)
            local wearable = math.max(nominal - reserve, 1e-6)
            local w = wheelCache and wheelCache[wheelID] or nil
            local wheelName = tostring((w and w.name) or wheelID)
            local fractions = {}
            for zone = 1, 3 do
                local depth = clamp(finiteNumber(data.tread_remaining_depth_m and data.tread_remaining_depth_m[zone], nominal), reserve, nominal)
                fractions[zone] = clamp((depth - reserve) / wearable, 0, 1)
            end
            local savedWearFeatures = {}
            local circState = type(data.circumferential_state) == "table" and data.circumferential_state or nil
            local currentPhase = M._circumferential.wrap01(circState and circState.phase or 0)
            if circState and type(circState.wearFeatures) == "table" then
                for _, feature in ipairs(circState.wearFeatures) do
                    if #savedWearFeatures >= M._circumferential.maxWearFeatures then break end
                    local meanFraction = {0, 0, 0}
                    local any = false
                    for zone = 1, 3 do
                        meanFraction[zone] = math.max(
                            finiteNumber(feature.meanM and feature.meanM[zone], 0), 0) / wearable
                        any = any or meanFraction[zone] > 0
                    end
                    if any then
                        savedWearFeatures[#savedWearFeatures + 1] = {
                            phase_offset_turns = M._circumferential.signedPhaseDelta(
                                finiteNumber(feature.phase, currentPhase), currentPhase),
                            half_width_turns = clamp(finiteNumber(feature.halfWidthTurns,
                                M._circumferential.minHalfWidthTurns),
                                M._circumferential.minHalfWidthTurns, M._circumferential.maxHalfWidthTurns),
                            mean_wearable_fraction = meanFraction,
                        }
                    end
                end
            end
            out.wheels[#out.wheels + 1] = {
                wheel_name = wheelName,
                tyre_internal_name = tostring(data.tyre_internal_name or (detected and detected.internalName) or ""),
                tyre_profile = tostring(data.tyre_profile_class or data.tyre_profile or ""),
                nominal_tread_depth_m = nominal,
                wearable_remaining_fraction = fractions,
                circumferential_wear_features = savedWearFeatures,
                condition = clamp(finiteNumber(data.condition, 100), 0, 100),
            }
        end
    end
    return out
end

M._careerWearPersistence.applyWheelIfPending = function(wheelID, data, profile, physical)
    local pending = M._careerWearPersistence.pending
    if type(pending) ~= "table" or type(pending.wheels) ~= "table" then return false end
    if M._careerWearPersistence.applied[wheelID] then return false end

    local w = wheelCache and wheelCache[wheelID] or nil
    local wheelName = tostring((w and w.name) or wheelID)
    local tyreName = tostring(data.tyre_internal_name or "")
    local saved = nil
    for _, candidate in ipairs(pending.wheels) do
        if type(candidate) == "table" and tostring(candidate.wheel_name or "") == wheelName then
            local savedTyre = tostring(candidate.tyre_internal_name or "")
            if savedTyre == "" or tyreName == "" or savedTyre == tyreName then
                saved = candidate
                break
            end
        end
    end
    if not saved then
        M._careerWearPersistence.applied[wheelID] = true
        return false
    end

    local nominal = math.max(finiteNumber(physical and physical.treadDepthM, 0.006), 0.001)
    local reserve = getNonWearableTreadReserveM(nominal)
    local wearable = math.max(nominal - reserve, 1e-6)
    data.tread_remaining_depth_m = type(data.tread_remaining_depth_m) == "table" and data.tread_remaining_depth_m or {}
    local fractions = type(saved.wearable_remaining_fraction) == "table" and saved.wearable_remaining_fraction or {}
    local sumDepth = 0
    for zone = 1, 3 do
        local frac = clamp(finiteNumber(fractions[zone], finiteNumber(saved.condition, 100) / 100), 0, 1)
        local depth = reserve + wearable * frac
        data.tread_remaining_depth_m[zone] = depth
        sumDepth = sumDepth + depth
    end
    data.condition = physicalTreadDepthToCondition(sumDepth / 3, nominal)
    data.tread_mean_remaining_depth_m = sumDepth / 3

    local circState = M._circumferential.ensureState(data)
    circState.thermalFeatures = {}
    circState.pendingBulkEnergyJ = nil
    circState.pendingBulkCellEnergyJ = {}
    M._circumferential.ensurePendingCells(circState, M._tread1D and M._tread1D.cells or 12)
    circState.wearFeatures = {}
    local savedFeatures = type(saved.circumferential_wear_features) == "table"
        and saved.circumferential_wear_features or {}
    local basePhase = M._circumferential.wrap01(circState.phase)
    for _, feature in ipairs(savedFeatures) do
        if #circState.wearFeatures >= M._circumferential.maxWearFeatures then break end
        if type(feature) == "table" then
            local fractionsByZone = type(feature.mean_wearable_fraction) == "table"
                and feature.mean_wearable_fraction or {}
            local meanM = {0, 0, 0}
            local any = false
            for zone = 1, 3 do
                meanM[zone] = math.max(finiteNumber(fractionsByZone[zone], 0), 0) * wearable
                any = any or meanM[zone] > 0
            end
            if any then
                circState.wearFeatures[#circState.wearFeatures + 1] = {
                    phase = M._circumferential.wrap01(basePhase
                        + clamp(finiteNumber(feature.phase_offset_turns, 0), -0.5, 0.5)),
                    halfWidthTurns = clamp(finiteNumber(feature.half_width_turns,
                        M._circumferential.minHalfWidthTurns),
                        M._circumferential.minHalfWidthTurns, M._circumferential.maxHalfWidthTurns),
                    meanM = meanM,
                }
            end
        end
    end

    data.career_wear_restored = true
    data.career_wear_schema = tonumber(pending.schema) or 1
    M._careerWearPersistence.applied[wheelID] = true
    return true
end

M.careerApplyWearState = function(inventoryId, state, restoreToken)
    if type(state) ~= "table" or type(state.wheels) ~= "table" then return false end
    M._careerWearPersistence.pending = cloneSerializable(state, nil)
    M._careerWearPersistence.applied = {}
    local invLiteral = serialize(inventoryId)
    local tokenLiteral = serialize(restoreToken)
    obj:queueGameEngineLua(
        "if career_modules_kagoniTyrePersistence and career_modules_kagoniTyrePersistence.confirmWearRestoreQueued then " ..
        "career_modules_kagoniTyrePersistence.confirmWearRestoreQueued(" .. invLiteral .. "," .. tokenLiteral .. ") end"
    )
    return true
end

M.careerSendWearState = function(inventoryId, saveToken)
    local state = M._careerWearPersistence.capture()
    if type(state.wheels) ~= "table" or #state.wheels < 1 then return false end
    local okState, stateLiteral = pcall(serialize, state)
    local okInv, invLiteral = pcall(serialize, inventoryId)
    local okToken, tokenLiteral = pcall(serialize, saveToken)
    if not okState or not okInv or not okToken then return false end
    obj:queueGameEngineLua(
        "if career_modules_kagoniTyrePersistence and career_modules_kagoniTyrePersistence.receiveVehicleWearState then " ..
        "career_modules_kagoniTyrePersistence.receiveVehicleWearState(" .. invLiteral .. "," .. stateLiteral .. "," .. tokenLiteral .. ") end"
    )
    return true
end

local function forzaRewindCaptureState()
    return {
        schema = 2,
        tyreData = cloneSerializable(tyreData, {}),
        tyreGripTable = cloneSerializable(tyreGripTable, {}),
        wheelFlashGripState = cloneSerializable(wheelFlashGripState, {}),
        wheelPressureReferenceCache = cloneSerializable(wheelPressureReferenceCache, {}),
        wheelWaterHold = cloneSerializable(wheelWaterHold, {}),
        vehicleWaterHold = vehicleWaterHold,
        totalTimeMod60 = totalTimeMod60,
        preheatRevision = preheatRevision,
        wheelPreheatRevision = cloneSerializable(wheelPreheatRevision, {}),
        pendingPreheatTargets = cloneSerializable(pendingPreheatTargets, {}),
        pendingPreheatModes = cloneSerializable(pendingPreheatModes, {}),
        sportPhysicalStiffness = cloneSerializable(M._sportPhysicalStiffness.captureRewindState(), {})
    }
end

local function restoreRewindThermalPressureDelta(wheelID, data)
    if type(data) ~= "table" then return false end

    local appliedDeltaPa = finiteNumber(data.thermal_pressure_cumulative_delta_pa, 0)
    local pressureGroupID = GetPressureGroupID(wheelID)
    local liveGaugePa, _, source = ReadActualPressureGroupGaugePa(wheelID)

    if liveGaugePa ~= nil then
        data.pressure_psi = liveGaugePa / PSI_TO_PA
        data.pressure_source = source
    end

    if pressureGroupID == nil then
        data.pressure_control_state = "rewind-thermal-delta-no-pressure-group"
        return false
    end

    local cachedWheel = wheelCache[wheelID]
    if cachedWheel and (cachedWheel.isTireDeflated or cachedWheel.isBroken) then
        data.pressure_control_state = "rewind-thermal-delta-native-deflated"
        return false
    end

    local initAbsolutePa = select(1, GetConfiguredPressureReferencePa(wheelID))
    if initAbsolutePa == nil then
        data.pressure_control_state = "rewind-thermal-delta-no-init-pressure"
        return false
    end

    local restoredAbsolutePa = math.max(initAbsolutePa + appliedDeltaPa, 1000)
    local ok = pcall(function()
        obj:setGroupPressure(pressureGroupID, restoredAbsolutePa)
    end)
    if not ok then
        pressureSetterAvailable = false
        data.pressure_control_state = "rewind-thermal-delta-setter-unavailable"
        return false
    end

    pressureSetterAvailable = true
    data.thermal_pressure_pending_delta_pa = finiteNumber(data.thermal_pressure_pending_delta_pa, 0)
    data.pressure_control_state = "beamng-native-init+restored-rewind-thermal-delta"
    UpdatePressureReadOnlyTelemetry(wheelID)
    return true
end

local function applyRestoredTyrePhysics()
    for wheelID, grip in pairs(tyreGripTable or {}) do
        grip = clamp(tonumber(grip) or 1, 0.02, 2.0)
        M._gripRefresh.forceWheel(wheelID, grip)
    end
    for wheelID, data in pairs(tyreData or {}) do
        restoreRewindThermalPressureDelta(wheelID, data)
    end
end

local function forzaRewindRestoreState(state, context)
    if type(state) ~= "table" then return false end
    local rewindSchema=tonumber(state.schema) or 1
    if rewindSchema ~= 1 and rewindSchema ~= 2 then return false end

    log("I", "luukstyrethermalsandwear", string.format(
        "Rewind tyre provider restore executing: vehicle=%s request=%s reassert=%s",
        tostring(type(context) == "table" and context.vehicleId or "unknown"),
        tostring(type(context) == "table" and context.restoreRequestId or "unknown"),
        tostring(type(context) == "table" and context.providerReassert == true)
    ))

    local requestId = math.floor(finiteNumber(
        type(context) == "table" and context.restoreRequestId,
        latestRewindRestoreRequestId + 1
    ))
    if requestId < latestRewindRestoreRequestId then
        log("I", "luukstyrethermalsandwear", string.format(
            "Ignored stale tyre provider restore: request=%d latest=%d",
            requestId, latestRewindRestoreRequestId
        ))
        return false
    end

    if type(context) == "table" and context.providerReassert == true and
       requestId == activeRewindSpinupRequestId then
        return true
    end
    latestRewindRestoreRequestId = requestId

    tyreData = cloneSerializable(state.tyreData, {})
    tyreGripTable = cloneSerializable(state.tyreGripTable, {})
    wheelFlashGripState = cloneSerializable(state.wheelFlashGripState, {})
    wheelPressureReferenceCache = cloneSerializable(state.wheelPressureReferenceCache, {})
    wheelWaterHold = cloneSerializable(state.wheelWaterHold, {})
    vehicleWaterHold = tonumber(state.vehicleWaterHold) or 0
    totalTimeMod60 = tonumber(state.totalTimeMod60) or 0
    preheatRevision = math.floor(tonumber(state.preheatRevision) or 0)
    wheelPreheatRevision = cloneSerializable(state.wheelPreheatRevision, {})

    M._thermalGripCacheByWheel = {}
    if M._pressureWheelBrush then M._pressureWheelBrush.slowCacheByWheel = {} end

    pendingPreheatTargets = {}
    pendingPreheatModes = {}
    local restoredThermalWheels = 0
    for wheelID, data in pairs(tyreData) do
        wheelPreheatRevision[wheelID] = preheatRevision
        if type(data) == "table" then
            data.thermal_cache_force_publish = true
            data.b100_slow_cache_dirty = true
        end
        if type(data) == "table" and type(data.temp) == "table" and
           tonumber(data.temp[1]) and tonumber(data.temp[2]) and
           tonumber(data.temp[3]) and tonumber(data.temp[4]) then
            restoredThermalWheels = restoredThermalWheels + 1
        end
    end

    if rewindSchema>=2 and type(state.sportPhysicalStiffness)=="table" then
        M._sportPhysicalStiffness.restoreRewindState(state.sportPhysicalStiffness)
        M._sportPhysicalStiffness.applyRestoredStructure()
    end

    if M._thermalPause.active then
        M._thermalPause.applyPeakGrip()
    end
    applyRestoredTyrePhysics()
    if not M._thermalPause.active then
        armRewindSpinupFreeze(context, tyreGripTable)
    end
    log("I", "luukstyrethermalsandwear", string.format(
        "Rewind tyre state restored for rewind: request=%d thermalWheels=%d autoPreheatCancelled=true mode=%s",
        requestId, restoredThermalWheels, tostring(type(context) == "table" and context.mode or "unknown")
    ))
    return true
end

local function forzaRewindCaptureUserState()
    return {
        schema = 2,
        wearEnabled = tyreWearEnabled == true,
        thermalsPaused = M._thermalPause.active == true
    }
end

local function forzaRewindApplyUserState(state)
    if type(state) ~= "table" then return false end
    local schema = tonumber(state.schema) or 1
    if schema ~= 1 and schema ~= 2 then return false end
    if state.wearEnabled ~= nil then setTyreWearEnabled(state.wearEnabled == true) end
    if state.thermalsPaused ~= nil then M._thermalPause.setActive(state.thermalsPaused == true) end
    return true
end

local function forzaRewindProviderInfo()
    return {
        id = "luukstyrethermalsandwear",
        api = 1,
        version = "1.5.0",
        supportsDynamicState = true,
        supportsSportEpsilonRewindRestore = true,
        supportsCloneUserState = true,
        supportsThermalPauseState = true,
        supportsRallyDirectionalBlockWear = true,
        supportsExclusiveRallySurfaceRouter = true,
        supportsAdaSurfaceCamberBridge = true,
        adaSurfaceCamberBridgeApi = 1
    }
end

local function onSerialize()
    return forzaRewindCaptureState()
end

local function onDeserialized(state)
    forzaRewindRestoreState(state)
end

M.forzaRewindCaptureState = forzaRewindCaptureState
M.forzaRewindRestoreState = forzaRewindRestoreState
M.forzaRewindCaptureUserState = forzaRewindCaptureUserState
M.forzaRewindApplyUserState = forzaRewindApplyUserState
M.forzaRewindProviderInfo = forzaRewindProviderInfo
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.setTyreWearEnabled = setTyreWearEnabled
M.getTyreWearEnabled = function() return tyreWearEnabled end
M.toggleTyreWear = toggleTyreWear
M.setThermalSimulationPaused = M._thermalPause.setActive
M.getThermalSimulationPaused = function() return M._thermalPause.active == true end
M.getSportPhysicalStiffnessState = M._sportPhysicalStiffness.getSummary
M.restorePeakGripAndPause = function() return M._thermalPause.setActive(true) end
M.getTuningValues = getTuningValues
M.getTuningNativeValues = getTuningNativeValues
M.setTuningValue = setTuningValue
M.resetTuningValue = resetTuningValue
M.resetAllTuningValues = resetAllTuningValues
M.setTyreProfilePreset = setTyreProfilePreset
M.getTyreProfilePreset = getTyreProfilePreset
M.setSlickCompoundPreset = M._slickCompounds.setPreset
M.getSlickCompoundPreset = M._slickCompounds.getPreset
M.setRallySurfacePreset = M._rallyCompounds.setSurfacePreset
M.getRallySurfacePreset = M._rallyCompounds.getSurfacePreset
M.setRallyCompoundPreset = M._rallyCompounds.setCompoundPreset
M.getRallyCompoundPreset = M._rallyCompounds.getCompoundPreset
M.setTyreStructuralPressureTarget = setTyreStructuralPressureTarget
M.clearTyreStructuralPressureTarget = clearTyreStructuralPressureTarget
M.preheatTyres = preheatTyres
M.preheatTyresAdvanced = M._advancedPreheat.apply
M.setRacingPitMode = M._pitStop.setEnabled
M.getRacingPitMode = function() return M._pitStop.enabled == true end
M.stagePitTyreProfile = M._pitStop.stageProfile
M.stagePitSlickCompound = M._pitStop.stageSlickCompound
M.stagePitRallySurface = M._pitStop.stageRallySurface
M.stagePitRallyCompound = M._pitStop.stageRallyCompound
M.stagePitTyrePressure = M._pitStop.stagePressure
M.stagePitPreheat = M._pitStop.stagePreheat
M.stagePitPreheatAdvanced = M._pitStop.stagePreheatAdvanced
M.setAxleTyrePressureOverride = M._axlePressureOverride.setImmediate
M.getAxleTyrePressureOverride = function(axle)
    axle = string.lower(tostring(axle or ""))
    if axle == "front" then return M._axlePressureOverride.frontPsi end
    if axle == "rear" then return M._axlePressureOverride.rearPsi end
    return nil
end
M.requestPitStop = M._pitStop.request
M.onSettingsChanged = onSettingsChanged
M.onInit = onInit
M.onReset = onReset
M.updateGFX = updateGFX
M.updatePhysics = function(dt)
    if not M._trafficSimulation.shouldRun() then return end
    M._rallyDirt.updatePhysicsRoute(dt)
    M._gripRefresh.updatePhysics(dt)
end
M.onVehicleSpawned = onVehicleSpawned
M.groundModelsCallback = groundModelsCallback

return M

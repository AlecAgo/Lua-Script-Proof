
local C = {}

-- Mouse / camera
C.Sensitivity = 0.20
C.PitchMin = -80
C.PitchMax = 80

-- Smoothness (higher = snappier, lower = heavier/laggier)
C.CameraSmooth = 18
C.BodyTurnSmooth = 14

-- Camera placement (relative to head)
C.CameraOffset = Vector3.new(0, 0.15, 0)

-- Mouse lock & cursor
C.LockMouse = true
C.HideMouseIcon = true

-- Character visibility in first person
C.HideCharacterInFP = true


-- Reduce sensitivity when exhausted (0.35 => up to -35% at exhaustion=1)
C.ExhaustSensitivityDrop = 0.35

-- Increase "heaviness" by effectively slowing camera/body smoothing as exhaustion rises
-- (0.55 => up to -55% smoothing speed at exhaustion=1)
C.ExhaustTurnLagBoost = 0.55

-- Minimum smoothing so it never becomes too sluggish/broken
C.MinCameraSmooth = 6
C.MinBodySmooth = 6

return C

-------------------------------------------------------------------------------
-- Copyright (c) 2015-present, Facebook, Inc.
-- All rights reserved.
-- This source code is licensed under the BSD-style license found in the
-- LICENSE file in the root directory of this source tree. An additional grant
-- of patent rights can be found in the PATENTS file in the same directory.
-------------------------------------------------------------------------------

-- UETorch lua library
print("Importing uetorch.lua ...")

-------------------------------------------------------------------------------
-- Lua ffi wrappers for UETorch C functions
-------------------------------------------------------------------------------
ffi = require 'ffi'
require 'torch'

ffi.cdef [[
typedef int32_t int32;

typedef struct {
  int32 X;
  int32 Y;
} IntSize;

struct UObject;
struct AActor;
struct UPrimitiveComponent;
struct UMaterial;
struct UPhysicalMaterial;
struct FName;
struct UPhysicsHandleComponent;

void GetViewportSize(IntSize* r);
bool CaptureScreenshot(IntSize* size, void* data);
bool CaptureSegmentation(UObject* _this, const IntSize* size, void* seg_data, int stride, const AActor** objects, int nObjects, const AActor** ignoredObjects, int nIgnoredObjects, bool verbose);
bool CaptureMasks(UObject* _this, const IntSize* size, void* seg_data, int stride, const AActor** objects, int nObjects, bool verbose);
bool CaptureOpticalFlow(UObject* _this, const IntSize* size, void* flow_data, void* rgb_data, float maxFlow, int stride, bool verbose);
bool CaptureDepthField(UObject* _this, AActor* object, const IntSize* size, void* data, int stride, bool verbose, const AActor** ignoredObjects, int nIgnoredObjects);

void PressKey(const char *key, int ControllerId, int eventType);
void SetMouse(int x, int y);
bool SetTickDeltaBounds(UObject* _this, float MinDeltaSeconds, float MaxDeltaSeconds);
bool SetResolution(int x, int y);
void ExecuteConsoleCommand(UObject* _this, char* command);

bool GetActorLocation(AActor* object, float* x, float* y, float* z);
bool GetActorRotation(AActor* object, float* pitch, float* yaw, float* roll);
bool GetActorVisible(AActor* object, bool* visible);
bool GetActorVelocity(AActor* object, float* x, float* y, float* z);
bool GetActorAngularVelocity(AActor* object, float* x, float* y, float* z);
bool GetActorScale3D(AActor* object, float* x, float* y, float* z);
bool GetActorBounds(AActor* object, float* x, float* y, float* z, float* boxX, float* boxY, float* boxZ);
bool GetActorForwardVector(AActor* object, float *x, float *y, float *z);

bool SetActorLocation(AActor* object, float x, float y, float z);
bool SetActorRotation(AActor* object, float pitch, float yaw, float roll);
bool SetActorLocationAndRotation(AActor* object, float x, float y, float z, float pitch, float yaw, float roll);
bool SetActorVisible(AActor* object, bool visible);
bool SetActorVelocity(AActor* object, float x, float y, float z);
bool SetActorAngularVelocity(AActor* object, float x, float y, float z);
bool SetActorScale3D(AActor* object, float x, float y, float z);

bool DestroyActor(AActor* object);

bool AddForce(AActor* object, float x, float y, float z);

bool SimpleMoveToLocation(UObject* _this, AActor* object, float x, float y, float z);
bool SimpleMoveToActor(UObject* _this, AActor* object, AActor* goal);

bool GrabComponent(UPhysicsHandleComponent* HandleComponent, UPrimitiveComponent* target, FName* InBoneName, float x, float y, float z);
bool ReleaseComponent(UPhysicsHandleComponent* HandleComponent);
bool SetTargetLocation(UPhysicsHandleComponent* component, float x, float y, float z);
bool WakeRigidBody(UPrimitiveComponent* component);
bool IgnoreCollisionWithPawn(UPrimitiveComponent* component);

bool CaptureDepthAndMasks(UObject* _this, const IntSize* size, int stride, AActor* origin, bool verbose, const AActor** objects, int nObjects, const AActor** ignoredObjects, int nIgnoredObjects, void* depth_data, void* mask_data);

bool SetMaterial(AActor* object, UMaterial* material);
bool GetMaterialPhysicalProperties(AActor* actor, float* props);
bool GetMassScale(AActor* actor, float* scale);
bool SetMassScale(AActor* actor, float scale);
bool GetMass(AActor* actor, float *mass);
bool SetPhysicalMaterial(AActor* actor, UPhysicalMaterial* physical);
bool SetNotifyRigidBodyCollision(AActor* actor, bool bNewNotifyRigidBodyCollision);
]]

local utlib = ffi.C

-------------------------------------------------------------------------------
-- REPL
--
-- start_repl() can be called from within an UETorch script directly,
-- or can be triggered (e.g. by a keypress) by setting up a blueprint event handler.
--
-- The REPL can be exited by typing `break`,
-- or the game can be run for `time` seconds before resuming the REPL
-- by typing `go(time)`.
--
-------------------------------------------------------------------------------

local uetorch = {}

local trepl = require 'trepl'

local co = coroutine.create(function ()
   while true do
      trepl()
      coroutine.yield()
   end
end)

-- Enter the REPL.
function uetorch.start_repl()
   coroutine.resume(co)
end

-- Add a global version so that it can be accessed from Blueprints
start_repl = uetorch.start_repl

local TimeRemaining = nil
local CountTicks = false

-- Typically called from the REPL.
-- Runs the game for `time` seconds (or `time` ticks if inTicks=true)
-- and then resumes the REPL.
function uetorch.go(time, inTicks)
   TimeRemaining = time or 1
   CountTicks = inTicks or false
   coroutine.yield()
end

-------------------------------------------------------------------------------
-- Tick handler
--
-- To register a function f(dt) to be called on every tick, you should call
-- `AddHook(f)`.
-------------------------------------------------------------------------------

local TickHooks = {}

-- add a tick 'hook' function f called at each game loop tick
-- tick hooks should take a single argument (dt) and return nothing.
function uetorch.AddTickHook(f)
   table.insert(TickHooks, f)
end

-- remove the function f from the set of tick hooks
function uetorch.RemoveTickHook(f)
   for i = #TickHooks, 1, -1 do
      if TickHooks[i] == f then
         table.remove(TickHooks, i)
      end
   end
end

-- remove all tick hooks
function uetorch.ClearTickHooks()
   TickHooks = {}
end

-- top-level tick handler
--
-- A TorchPluginComponent calls the Tick function at every tick of the Unreal
-- game engine loop. dt is the delta time for this tick.
--
-- This top level handler mostly delegates to tick hooks registered with AddHook().
-- It also manages the REPL and keyboard input.
--
-- IMPORTANT:
-- This function should only be called from TorchPluginComponent::Tick()
--

function Tick(dt)
   uetorch._UntapKeys()
   if CountTicks then dt = 1 end
   if TimeRemaining then
      TimeRemaining = TimeRemaining - dt
      if TimeRemaining <= 0 then
         TimeRemaining = nil
         CountTicks = false
         start_repl()
      end
   end

   for ii, hook in ipairs(TickHooks) do
      hook(dt)
   end
end

-- Set minimum and maximum delta time for each game engine loop 'tick'.
-- By default, UnrealEngine adjusts the tick length to correspond to real time,
-- so that the game proceeds in real time. Calling SetTickDeltaBounds with
-- min == max fixes the tick rate of the game.
-- This is useful for running at faster-than-real-time, and also ensures
-- a consistent tick rate for reproducible simulation, fixed-fps screenshots,
--  etc.
function uetorch.SetTickDeltaBounds(min, max)
   return utlib.SetTickDeltaBounds(this, min, max)
end

-- Simple function to set the exact FPS. This will make the game run at slower
-- or faster than real time depending on the speed of your system.
function uetorch.SetFPS(fps)
  return utlib.SetTickDeltaBounds(this, 1/fps, 1/fps)
end


-------------------------------------------------------------------------------
-- Keyboard input
--
-- see https://wiki.unrealengine.com/List_of_Key/Gamepad_Input_Names
-- for a full list of key names
-------------------------------------------------------------------------------

local IE_PRESSED = 0
local IE_RELEASED = 1

-- press and hold the key with this name
function uetorch.PressKey(key)
   utlib.PressKey(key, 0, IE_PRESSED)
end

-- release the key with this name
function uetorch.ReleaseKey(key)
   utlib.PressKey(key, 0, IE_RELEASED)
end

local _tapped = {}
function uetorch._UntapKeys()
   for i,v in ipairs(_tapped) do
      uetorch.ReleaseKey(v)
   end
   _tapped = {}
end

-- press the key with this name, and release it on the next tick
function uetorch.TapKey(k)
   uetorch.PressKey(k)
   table.insert(_tapped, k)
end

-------------------------------------------------------------------------------
--
-- Torch wrappers for data capture functions.
-- screenshot, segmentation, optical flow, etc.
--
-------------------------------------------------------------------------------

-- Get an FFI pointer to an Unreal Actor object by name.
-- Needed as input to the segmentation/masks functions.
--
-- Parameters:
--     name: The 'ID name' of the object
-- Returns:
--     An FFI pointer to the Actor object,
--     or nil if no actor with this name exists.
function uetorch.GetActor(name)
   local level = UE.GetFullName(UE.GetCurrentLevel(this))
   level = string.sub(level, 7, -1) -- remove "Level"
   local actor = UE.FindObject(Actor.Class(), nil, level..'.'..name)
   if tostring(actor) ~= 'userdata: (nil)' then
      return actor
   else
      return nil
   end
end

-- Capture a screenshot of the viewport
--
-- Parameters:
--     tensor: a FloatTensor of size (3,Y,X) to store the output screenshot
-- Returns:
--     true if the screenshot has been correctly captured, false otherwise
function uetorch.Screen(tensor)
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)

   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return false
   end

   if not utlib.CaptureScreenshot(size, tensor:data()) then
      print("ERROR: Unable to capture screenshot")
      return false
   end

   return true
end


-- Capture segmentation masks for a set of objects in the viewport image.
--
-- Do the same as uetorch.ObjectSegmentation on a pre-allocated tensor
--
-- Parameters:
--     tensor: an IntTensor of size [Y/stride,X/stride] to store the
--             captured segmentation
--     objects: a list of ffi Actor* pointers, for which segmentation masks should
--              be recorded.
--     ignored_objects: a list of ffi Actor* pointers which are ignored
--                      by the ray tracing algorithm during segmentation.
--     stride: stride in pixels at which to compute the masks. (Default: 1)
--     verbose: verbose output (Default: false)
--     size: optional, size of the viewport
--
-- Returns:
--    true if the segmentation has been correctly captured, false otherwise
function uetorch.ObjectSegmentationNoAlloc(
      tensor, objects, ignored_objects, stride, verbose, size)
   assert(objects, "must specify objects for segmentation")

   stride = stride or 1
   verbose = verbose or false
   if not size then
      size = size or ffi.new('IntSize[?]', 1)
      utlib.GetViewportSize(size)
   end

   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return false
   end

   local objectArr = ffi.new(string.format("AActor*[%d]", #objects), objects)

   local captured = false
   if not ignored_objects or #ignored_objects == 0 then
      -- no objects to ignore
      if(verbose) then print('no object to ignore') end
      captured = utlib.CaptureSegmentation(
         this, size, tensor:data(), stride,
         objectArr, #objects, nil, 0, verbose)
   else
      -- do not segment actors to ignore
      if(verbose) then print('ignoring ' .. #ignored_objects .. ' objects') end
      local ignoredObjectArr = ffi.new(string.format("AActor*[%d]", #ignored_objects), ignored_objects)
      captured = utlib.CaptureSegmentation(
         this, size, tensor:data(), stride,
         objectArr, #objects, ignoredObjectArr, #ignored_objects, verbose)
   end

   if not captured then
      print("ERROR: Unable to capture segmentation")
      return false
   end

end


-- Capture segmentation masks for a set of objects in the viewport image.
--
-- Allocate a tensor, delegate the segmentation to
-- uetorch.ObjectSegmentationNoAlloc and return the tensor, or nil if
-- the capture failed.
--
-- Parameters:
--     objects: a list of ffi Actor* pointers, for which segmentation
--              masks should be recorded.
--     ignored_objects: a list of ffi Actor* pointers which are ignored
--                      by the ray tracing algorithm during segmentation.
--     stride: stride in pixels at which to compute the masks. (Default: 1)
--     verbose: verbose output (Default: false)
--
-- Returns:
--     an IntTensor of size [Y/stride,X/stride].
--     Each value corresponds to the index in the `objects` list of the foreground
--     object at this viewport pixel, or 0 if there is no object from the list at
--     that location in the viewport.
--
function uetorch.ObjectSegmentation(objects, ignored_objects, stride, verbose)
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)

   local tensor = torch.IntTensor(
      math.ceil(size[0].Y/stride),
      math.ceil(size[0].X/stride))

   if uetorch.ObjectSegmentationNoAlloc(
      tensor, objects, ignored_objects, stride, verbose, size)
   then
      return tensor
   else
      return nil
   end
end


-- Capture segmentation masks for a set of objects in the viewport image, including
-- occluded objects. Since there can be multiple (occluded) objects at each pixel, this
-- function returns #objects binary masks instead of a single int mask.
--
-- Parameters:
--     objects: a list of ffi Actor* pointers, for which segmentation masks should
--              be recorded.
--     stride: stride in pixels at which to compute the masks. (Default: 1)
--     verbose: verbose output (Default: false)
--
-- Returns:
--     a ByteTensor of size [#objects,Y/stride,X/stride].
--     Each value mask[i,x,y] is 1 if object[i] is in the line of sight
--     at pixel [y*stride,x*stride] (even if occluded), and 0 otherwise.
function uetorch.ObjectMasks(objects, stride, verbose)
   assert(objects, "must specify objects for segmentation")
   stride  = stride or 1
   verbose = verbose or false
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)

   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return nil
   end

   local masks = torch.ByteTensor(math.ceil(size[0].Y/stride),
                                  math.ceil(size[0].X/stride),
                                  #objects)

   local objectArr = ffi.new(string.format("AActor*[%d]",#objects), objects)

   if not utlib.CaptureMasks(this, size, masks:storage():cdata().data, stride, objectArr, #objects, verbose) then
      print("ERROR: Unable to capture segmentation")
      return nil
   end

   masks = masks:transpose(1,3):transpose(2,3)
   return masks
end

-- Capture the optical flow at each pixel in the viewport.
--
-- Parameters:
--     maxFlow: the scale for computing the RGB flow. A flow of
--              maxFlow pixels/s will correspond to a fully saturated
--              RGB output. (Default: 1)
--     stride: stride in pixels at which to compute the optical flow. (Default: 1)
--     verbose: verbose output (Default: false)
-- Returns:
--     flow: A FloatTensor of size (2,Y/stride,X/stride) containing the 2D
--           optical flow at each point in the viewport.
--     rgb:  A FloatTensor of size (3,Y/stride,X/stride) containing the 2D
--           optical flow converted to RGB color, where hue represents direction
--           and saturation represents magnitude. The scale is specified by maxFlow,
--           so the RGB image is saturated at flow=maxFlow.
function uetorch.OpticalFlow(maxFlow, stride, verbose)
   maxFlow = maxFlow or 1
   stride = stride or 1
   verbose = verbose or false
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)

   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return nil
   end

   local flow = torch.FloatTensor(math.ceil(size[0].Y/stride),
                  math.ceil(size[0].X/stride),
                  2)
   local rgb  = torch.FloatTensor(math.ceil(size[0].Y/stride),
                  math.ceil(size[0].X/stride),
                  3)

   if not utlib.CaptureOpticalFlow(this, size, flow:storage():cdata().data, rgb:storage():cdata().data, maxFlow, stride, verbose) then
      print("ERROR: Unable to capture optical flow")
      return nil
   end
   flow = flow:transpose(1,3):transpose(2,3)
   rgb  = rgb:transpose(1,3):transpose(2,3)

   return flow, rgb
end

-- Capture the depth field at each pixel in the viewport.
--
-- Parameters:
--     actor: the actor from which we will calculate the depth field
--     ignored_objects: a list of ffi Actor* pointers which are ignored
--                      by the ray tracing algorithm during depth fiels estimation.
--     stride: stride in pixels at which to compute the depth field. (Default: 1)
--     verbose: verbose output (Default: false)
--
-- Returns:
--     depth: A FloatTensor of size (Y/stride,X/stride) containing the 2D
--            depth field at each point in the viewport.
--
function uetorch.DepthField(actor, ignored_objects, stride, verbose)
   stride = stride or 1
   verbose = verbose or false
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)

   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return nil
   end

   local depth = torch.FloatTensor(math.ceil(size[0].Y/stride),
                   math.ceil(size[0].X/stride))

   local captured = false
   if not ignored_objects or #ignored_objects == 0 then  -- no objects to ignore
      if(verbose) then print('depth: no object to ignore') end
      captured = utlib.CaptureDepthField(
         this, actor, size, depth:storage():cdata().data, stride, verbose, nil, 0)
   else
      if(verbose) then print('depth: ignoring ' .. #ignored_objects .. ' objects') end
      local ignoredObjectArr = ffi.new(string.format("AActor*[%d]", #ignored_objects), ignored_objects)
      captured = utlib.CaptureDepthField(
         this, actor, size, depth:storage():cdata().data, stride, verbose,
         ignoredObjectArr, #ignored_objects)
   end

   if not captured then
      print("ERROR: Unable to capture depth field")
      return nil
   end

   return depth
end


-- Capture depth field and segmentation masks for a set of objects in the viewport.
--
-- Store the result in pre-allocated tensors given as the `mask` and
-- `depth` parameters of the function.
--
-- Parameters:
--     origin: the actor from which we will calculate the depth field
--     active_objects: a list of ffi Actor* pointers, for which segmentation masks should
--                     be recorded.
--     ignored_objects: a list of ffi Actor* pointers which are ignored
--                      by the ray tracing algorithm during segmentation.
--     depth: A FloatTensor of size (Y/stride,X/stride) to store the depth field
--     mask: a IntTensor of size [Y/stride,X/stride].
--           Each value corresponds to the index in the `objects` list of the foreground
--           object at this viewport pixel, or 0 if there is no object from the list at
--           that location in the viewport.
--     stride: stride in pixels at which to compute the masks. (Default: 1)
--     verbose: verbose output (Default: false)
--
-- Returns: true if the capture is successful, false oteherwise
function uetorch.CaptureDepthAndMasks(
      origin, active_objects, ignored_objects, depth, mask, stride, verbose)
   -- arguments check
   assert(active_objects, "must specify objects for segmentation")
   stride = stride or 1
   verbose = verbose or false

   -- retrieve the viewport size
   local size = ffi.new('IntSize[?]', 1)
   utlib.GetViewportSize(size)
   if size[0].X == 0 or size[0].Y == 0 then
      print("ERROR: Screen not visible")
      return nil
   end

   local objectArr = ffi.new(string.format("AActor*[%d]", #active_objects), active_objects)

   local captured = false
   if not ignored_objects or #ignored_objects == 0 then  -- no objects to ignore
      if(verbose) then print('no object to ignore') end

      captured = utlib.CaptureDepthAndMasks(
         this, size, stride, origin, verbose,
         objectArr, #active_objects, nil, 0,
         depth:data(), mask:data())
   else
      if(verbose) then print('ignoring ' .. #ignored_objects .. ' objects') end

      local ignoredObjectArr = ffi.new(string.format("AActor*[%d]", #ignored_objects), ignored_objects)

      captured = utlib.CaptureDepthAndMasks(
         this, size, stride, origin, verbose,
         objectArr, #active_objects, ignoredObjectArr, #ignored_objects,
         depth:data(), mask:data())
   end

   if not captured then
      print("ERROR: Unable to capture depth and masks")
      return false
   end

   return true
end

-------------------------------------------------------------------------------
--
-- Actor properties
--
-- see https://docs.unrealengine.com/latest/INT/API/Runtime/Engine/GameFramework/AActor/index.html
-- and https://docs.unrealengine.com/latest/INT/API/Runtime/Engine/Components/UPrimitiveComponent/index.html
-- for further reference
-------------------------------------------------------------------------------

function uetorch.GetActorLocation(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   if not utlib.GetActorLocation(actor,x,y,z) then
      return nil
   end
   return {x = x[0],y = y[0],z = z[0]}
end

function uetorch.GetActorRotation(actor)
   local pitch = ffi.new('float[?]', 1)
   local yaw = ffi.new('float[?]', 1)
   local roll = ffi.new('float[?]', 1)
   if not utlib.GetActorRotation(actor,pitch,yaw,roll) then
      return nil
   end
   return {pitch = pitch[0], yaw = yaw[0], roll = roll[0]}
end

function uetorch.GetActorVisible(actor)
   local visible = ffi.new('bool[?]', 1)
   if not utlib.GetActorVisible(actor, visible) then
      return nil
   end
   return visible[0]
end

function uetorch.GetActorVelocity(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   if not utlib.GetActorVelocity(actor,x,y,z) then
      return nil
   end
   return {x = x[0], y = y[0],z = z[0]}
end

function uetorch.GetActorAngularVelocity(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   if not utlib.GetActorAngularVelocity(actor,x,y,z) then
      return nil
   end
   return {x = x[0], y = y[0], z = z[0]}
end

function uetorch.GetActorScale3D(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   if not utlib.GetActorScale3D(actor,x,y,z) then
      return nil
   end
   return {x = x[0], y = y[0], z = z[0]}
end

function uetorch.GetActorBounds(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   local boxX = ffi.new('float[?]', 1)
   local boxY = ffi.new('float[?]', 1)
   local boxZ = ffi.new('float[?]', 1)
   if not utlib.GetActorBounds(actor,x,y,z,boxX,boxY,boxZ) then
      return nil
   end
   return {x = x[0], y = y[0], z = z[0], boxX = boxX[0], boxY = boxY[0], boxZ = boxZ[0]}
end

function uetorch.GetActorForwardVector(actor)
   local x = ffi.new('float[?]', 1)
   local y = ffi.new('float[?]', 1)
   local z = ffi.new('float[?]', 1)
   if not utlib.GetActorForwardVector(actor,x,y,z) then
      return nil
   end
   return {x = x[0], y = y[0], z = z[0]}
end


uetorch.SetActorLocation = utlib.SetActorLocation
uetorch.SetActorRotation = utlib.SetActorRotation
uetorch.SetActorLocationAndRotation = utlib.SetActorLocationAndRotation
uetorch.SetActorVisible = utlib.SetActorVisible
uetorch.SetActorVelocity = utlib.SetActorVelocity
uetorch.SetActorAngularVelocity = utlib.SetActorAngularVelocity
uetorch.SetActorScale3D = utlib.SetActorScale3D
uetorch.DestroyActor = utlib.DestroyActor
uetorch.SetMouse = utlib.SetMouse

-------------------------------------------------------------------------------
--
-- Pawn control
--
-- see https://docs.unrealengine.com/latest/INT/API/Runtime/Engine/GameFramework/APawn/index.html
-- and https://docs.unrealengine.com/latest/INT/API/Runtime/Engine/GameFramework/AController/index.html
-- for further reference
-------------------------------------------------------------------------------

function uetorch.SimpleMoveToLocation(actor, x, y, z)
   return utlib.SimpleMoveToLocation(this, actor, x, y, z)
end

function uetorch.SimpleMoveToActor(actor, goal)
   return utlib.SimpleMoveToActor(this, actor, goal)
end

-------------------------------------------------------------------------------
--
-- Handling (Grabbing and releasing) of actors
--
-- see https://docs.unrealengine.com/latest/INT/BlueprintAPI/Physics/Components/PhysicsHandle/index.html
-- for further reference
-------------------------------------------------------------------------------

uetorch.GrabComponent = utlib.GrabComponent
uetorch.ReleaseComponent = utlib.ReleaseComponent
uetorch.SetTargetLocation = utlib.SetTargetLocation
uetorch.WakeRigidBody = utlib.WakeRigidBody
uetorch.IgnoreCollisionWithPawn = utlib.IgnoreCollisionWithPawn

-------------------------------------------------------------------------------
-- Execute UE commands
-- For example: RestartLevel
-- For a detailed list run dumpconsolecommands in the command line
--
-------------------------------------------------------------------------------

function uetorch.ExecuteConsoleCommand(command)
   local len = #command + 1
   local char_command = ffi.new('char[' .. len .. ']', command)
   utlib.ExecuteConsoleCommand(this, char_command)
end



function uetorch.GetMaterialPhysicalProperties(actor)
   local props = ffi.new('float[?]', 3)
   if not utlib.GetMaterialPhysicalProperties(actor, props) then
      return nil
   end
   return {friction = props[0], restitution = props[1], density = props[2]}
end


function uetorch.GetMassScale(actor)
   local scale = ffi.new('float[?]', 1)
   if not utlib.GetMassScale(actor, scale) then
      return nil
   end
   return scale[0]
end

function uetorch.GetMass(actor)
   local mass = ffi.new('float[?]', 1)
   if not utlib.GetMass(actor, mass) then
      return nil
   end
   return mass[0]
end


-- uetorch.SetFriction = utlib.SetFriction
uetorch.SetPhysicalMaterial = utlib.SetPhysicalMaterial
uetorch.SetMassScale = utlib.SetMassScale
uetorch.SetMaterial = utlib.SetMaterial
uetorch.AddForce = utlib.AddForce
uetorch.SetResolution = utlib.SetResolution
uetorch.SetNotifyRigidBodyCollision = utlib.SetNotifyRigidBodyCollision


return uetorch

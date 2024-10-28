# cmain.pyx
# cython: language_level=3
import numpy as np
cimport numpy as cnp
from mathutils import Vector
from grid cimport MACGrid
from scipy.sparse import csr_matrix
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import cg 

cdef enum Component:
    U = 0
    V = 1
    W = 2
    S = -1

# -- Interpolation --

cdef void get_index_and_offset(double[:] pos, double cell_size, cnp.npy_intp *field_shape,
                               cnp.npy_intp* i, cnp.npy_intp* j, cnp.npy_intp* k,
                               double* fx, double* fy, double* fz, Component component):
    # Get i, j, k and fx, fy, fz for interpolation, from position
    cdef double x = pos[0] / cell_size
    cdef double y = pos[1] / cell_size
    cdef double z = pos[2] / cell_size
    if component == Component.U:
        i[0] = <cnp.npy_intp>x
        j[0] = <cnp.npy_intp>(y - 0.5)
        k[0] = <cnp.npy_intp>(z - 0.5)
        fx[0] = x - i[0]
        fy[0] = (y - 0.5) - j[0]
        fz[0] = (z - 0.5) - k[0]
    elif component == Component.V:
        i[0] = <cnp.npy_intp>(x - 0.5)
        j[0] = <cnp.npy_intp>y
        k[0] = <cnp.npy_intp>(z - 0.5)
        fx[0] = (x - 0.5) - i[0]
        fy[0] = y - j[0]
        fz[0] = (z - 0.5) - k[0]
    elif component == Component.W:
        i[0] = <cnp.npy_intp>(x - 0.5)
        j[0] = <cnp.npy_intp>(y - 0.5)
        k[0] = <cnp.npy_intp>z
        fx[0] = (x - 0.5) - i[0]
        fy[0] = (y - 0.5) - j[0]
        fz[0] = z - k[0]
    else: # Scalar field
        i[0] = <cnp.npy_intp>x
        j[0] = <cnp.npy_intp>y
        k[0] = <cnp.npy_intp>z
        fx[0] = x - i[0]
        fy[0] = y - j[0]
        fz[0] = z - k[0]
    # Clamp Indexes
    if i[0] < 0:
        i[0] = 0
    elif i[0] > field_shape[0] - 2:
        i[0] = field_shape[0] - 2
    if j[0] < 0:
        j[0] = 0
    elif j[0] > field_shape[1] - 2:
        j[0] = field_shape[1] - 2
    if k[0] < 0:
        k[0] = 0
    elif k[0] > field_shape[2] - 2:
        k[0] = field_shape[2] - 2
    # Clamp Offsets
    fx[0] = max(0.0, min(fx[0], 1.0))
    fy[0] = max(0.0, min(fy[0], 1.0))
    fz[0] = max(0.0, min(fz[0], 1.0))

cpdef double interp_dir(double u1, double u2, double fdir):
    return (u1 * (1 - fdir) + u2 * fdir) 

cpdef double trilinear_interpolate(cnp.ndarray face_u, cnp.npy_intp i, cnp.npy_intp j, cnp.npy_intp k, double fx, double fy, double fz):
    '''Main trilinear interpolation function, find velocity of a component (u, v, w)
    Grid cell index: (i, j, k) , Offset from grid cell: (fx, fy, fz)'''
    cdef double u000, u100, u010, u110, u001, u101, u011, u111
    # Grid dims
    cdef cnp.npy_intp n0 = face_u.shape[0]
    cdef cnp.npy_intp n1 = face_u.shape[1]
    cdef cnp.npy_intp n2 = face_u.shape[2]
    # Velocity of each face
    u000 = face_u[i, j, k]
    u100 = face_u[min(i+1, n0-1), j, k]#i+1
    u010 = face_u[i, min(j+1, n1-1), k]#j+1
    u110 = face_u[min(i+1, n0-1), min(j+1, n1-1), k]#i+1, j+1
    u001 = face_u[i, j, min(k+1, n2-1)]#k+1
    u101 = face_u[min(i+1, n0-1), j, min(k+1, n2-1)]#i+1, k+1
    u011 = face_u[i, min(j+1, n1-1), min(k+1, n2-1)]#j+1, k+1
    u111 = face_u[min(i+1, n0-1), min(j+1, n1-1), min(k+1, n2-1)]#i+1, j+1, k+1
    # Interpolate x
    cdef double c00 = interp_dir(u000, u100, fx)
    cdef double c01 = interp_dir(u001, u101, fx)
    cdef double c10 = interp_dir(u010, u110, fx)
    cdef double c11 = interp_dir(u011, u111, fx)
    # Interpolate y
    cdef double c0 = interp_dir(c00, c10, fy)
    cdef double c1 = interp_dir(c01, c11, fy)
    # Interpolate z
    cdef double c = interp_dir(c0, c1, fz)
    return c

cpdef cnp.ndarray interp_u_at_p(MACGrid grid, cnp.ndarray pos):
    # Get the whole velocity vector from a position
    cdef double cs = grid.cell_size
    cdef double x = pos[0]/cs
    cdef double y = pos[1]/cs
    cdef double z = pos[2]/cs
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef cnp.npy_intp i = min(max(int(x), 0), nx - 2)
    cdef cnp.npy_intp j = min(max(int(y), 0), ny - 2)
    cdef cnp.npy_intp k = min(max(int(z), 0), nz - 2)
    cdef double fx = min(max(x - i, 0.0), 1.0)
    cdef double fy = min(max(y - j, 0.0), 1.0)
    cdef double fz = min(max(z - k, 0.0), 1.0)
    cdef cnp.ndarray[double, ndim=1] vel = np.zeros(3, dtype=np.float64)
    vel[0] = trilinear_interpolate(grid.u, i, j, k, fx, fy, fz)  # U-component
    vel[1] = trilinear_interpolate(grid.v, i, j, k, fx, fy, fz)  # V-component
    vel[2] = trilinear_interpolate(grid.w, i, j, k, fx, fy, fz)  # W-component
    return vel

cpdef double interp_component_u_at_p(cnp.ndarray face_vel, cnp.ndarray pos, Component component, MACGrid grid):
    # Interpolate one component (u, v, w)
    cdef cnp.npy_intp i = 0, j = 0, k = 0  
    cdef double fx = 0.0, fy = 0.0, fz = 0.0 
    get_index_and_offset(pos, grid.cell_size, &face_vel.shape[0], &i, &j, &k, &fx, &fy, &fz, component)
    return trilinear_interpolate(face_vel, i, j, k, fx, fy, fz)

cpdef double interp_scalar_u_at_p(cnp.ndarray scalar_field, cnp.ndarray pos, double cell_size):
    # Interpolate a scalar (i.e pressure)
    cdef cnp.npy_intp i = 0, j = 0, k = 0 
    cdef double fx = 0.0, fy = 0.0, fz = 0.0 
    get_index_and_offset(pos, cell_size, &scalar_field.shape[0], &i, &j, &k, &fx, &fy, &fz, Component.S)
    return trilinear_interpolate(scalar_field, i, j, k, fx, fy, fz)

''' -- Simulation Functions -- '''

# -- Calculate DT

cpdef double calc_dt(MACGrid grid, double initial_dt, double cell_size, cnp.ndarray wind_acceleration):
    cdef double cfl = 0.5
    cdef double force = np.linalg.norm(wind_acceleration)
    cdef double umax = grid.max_vel + (cell_size * force) ** 0.5
    return cfl * (cell_size / umax) if umax != 0 else cell_size

# -- Apply wind force --

cpdef void cy_predict_wind(MACGrid grid, double dt, cnp.ndarray[double, ndim=1] wind_speed, cnp.ndarray[double, ndim=1] wind_acceleration, double damping_factor):
    cdef cnp.npy_intp x, y, z
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    for x in range(nx + 1):
        for y in range(ny):
            for z in range(nz):
                grid.u[x, y, z] *= damping_factor
                if grid.u[x, y, z] < wind_speed[0]:
                    grid.u[x, y, z] += wind_acceleration[0] * dt
                grid.u[x, y, z] = max(min(grid.u[x, y, z], wind_speed[0]), -wind_speed[0])
    for x in range(nx):
        for y in range(ny + 1):
            for z in range(nz):
                grid.v[x, y, z] *= damping_factor
                if grid.v[x, y, z] < wind_speed[1]:
                    grid.v[x, y, z] += wind_acceleration[1] * dt
                grid.v[x, y, z] = max(min(grid.v[x, y, z], wind_speed[1]), -wind_speed[1])
    for x in range(nx):
        for y in range(ny):
            for z in range(nz + 1):
                grid.w[x, y, z] *= damping_factor
                if grid.w[x, y, z] < wind_speed[2]:
                    grid.w[x, y, z] += wind_acceleration[2] * dt
                grid.w[x, y, z] = max(min(grid.w[x, y, z], wind_speed[2]), -wind_speed[2])
    print("U-velocity statistics after wind prediction:")
    print("Min:", np.min(grid.u), "Max:", np.max(grid.u))

    print("V-velocity statistics after wind prediction:")
    print("Min:", np.min(grid.v), "Max:", np.max(grid.v))

    print("W-velocity statistics after wind prediction:")
    print("Min:", np.min(grid.w), "Max:", np.max(grid.w))


# -- Collisions --

cpdef void redirect_velocity(MACGrid grid, cnp.ndarray location, cnp.ndarray normal, cnp.npy_intp x, cnp.npy_intp y, cnp.npy_intp z, double damping_factor, double friction):
    cdef cnp.ndarray vel = interp_u_at_p(grid, location)
    cdef cnp.ndarray reflected_u, tangent_u
    cdef double damping = 0.8
    reflected_u = (vel - 2 * np.dot(vel, normal) * normal) * damping
    tangent_u = (reflected_u - np.dot(reflected_u, normal) * normal)
    reflected_u -= friction * tangent_u
    grid.set_face_velocities(x, y, z, reflected_u)

cpdef void cy_collide(MACGrid grid, object bvh_tree, double dt, double damping_factor, double friction):
    # Perform collision check and redirect
    cdef cnp.npy_intp x, y, z
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef cnp.ndarray pos = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray vel = np.zeros(3, dtype=np.float64)
    cdef double cell_size = grid.cell_size
    cdef object location, normal, distance
    for x in range(nx):
        for y in range(ny):
            for z in range(nz):
                pos[:] = grid.get_cell_position(x, y, z)
                vel[:] = interp_u_at_p(grid, pos)
                if np.linalg.norm(vel) == 0:
                    continue
                origin = Vector(pos - vel * dt)
                direction = Vector(vel / np.linalg.norm(vel))
                location, normal, _, distance = bvh_tree.ray_cast(origin, direction, np.linalg.norm(vel) * dt)
                if location is not None and distance <= np.linalg.norm(vel) * dt: #Collision
                    new_pos = pos + (np.array(normal) * (np.linalg.norm(vel) * dt - distance))
                    grid.position[x, y, z, :] = new_pos
                    redirect_velocity(grid, np.array(location, dtype=np.float64), np.array(normal, dtype=np.float64), x, y, z, damping_factor, friction)

# -- Velocity Advection --

cpdef void cy_advect_velocities(MACGrid grid, double dt):
    # Apply new velocities from collision with RK3 (Runge Kutta Order-3) method
    cdef cnp.ndarray uk1 = np.zeros_like(grid.u)
    cdef cnp.ndarray vk1 = np.zeros_like(grid.v)
    cdef cnp.ndarray wk1 = np.zeros_like(grid.w)
    cdef cnp.ndarray uk2 = np.zeros_like(grid.u)
    cdef cnp.ndarray vk2 = np.zeros_like(grid.v)
    cdef cnp.ndarray wk2 = np.zeros_like(grid.w)
    cdef cnp.ndarray uk3 = np.zeros_like(grid.u)
    cdef cnp.ndarray vk3 = np.zeros_like(grid.v)
    cdef cnp.ndarray wk3 = np.zeros_like(grid.w)
    cdef cnp.ndarray new_u = np.zeros_like(grid.u)
    cdef cnp.ndarray new_v = np.zeros_like(grid.v)
    cdef cnp.ndarray new_w = np.zeros_like(grid.w)
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef cnp.npy_intp x, y, z
    cdef cnp.ndarray pos = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray temp_pos = np.zeros(3, dtype=np.float64)
    cdef double cell_size = grid.cell_size
    for x in range(nx+1):
        for y in range(ny):
            for z in range(nz):
                pos[0] = x * cell_size
                pos[1] = (y + 0.5) * cell_size
                pos[2] = (z + 0.5) * cell_size
                uk1[x, y, z] = interp_component_u_at_p(grid.u, pos, Component.U, grid)
                temp_pos[:] = pos + .5 * dt * uk1[x, y, z]
                uk2[x, y, z] = interp_component_u_at_p(grid.u, temp_pos, Component.U, grid)
                temp_pos[:] = pos + .75 * dt * uk2[x, y, z]
                uk3[x, y, z] = interp_component_u_at_p(grid.u, temp_pos, Component.U, grid)
                new_u[x, y, z] = grid.u[x, y, z] + (2/9) * dt * uk1[x, y, z] + (3/9) * dt * uk2[x, y, z] + (4/9) * dt * uk3[x, y, z]
    for x in range(nx):
        for y in range(ny+1):
            for z in range(nz):
                pos[0] = (x + 0.5) * cell_size
                pos[1] = y * cell_size
                pos[2] = (z + 0.5) * cell_size
                vk1[x, y, z] = interp_component_u_at_p(grid.v, pos, Component.V, grid)
                temp_pos[:] = pos + .5 * dt * vk1[x, y, z]
                vk2[x, y, z] = interp_component_u_at_p(grid.v, temp_pos, Component.V, grid)
                temp_pos[:] = pos + .75 * dt * vk2[x, y, z]
                vk3[x, y, z] = interp_component_u_at_p(grid.v, temp_pos, Component.V, grid)
                new_v[x, y, z] = grid.v[x, y, z] + (2/9) * dt * vk1[x, y, z] + (3/9) * dt * vk2[x, y, z] + (4/9) * dt * vk3[x, y, z]
    for x in range(nx):
        for y in range(ny):
            for z in range(nz+1):
                pos[0] = (x + 0.5) * cell_size
                pos[1] = (y + 0.5) * cell_size
                pos[2] = z * cell_size
                wk1[x, y, z] = interp_component_u_at_p(grid.w, pos, Component.W, grid)
                temp_pos[:] = pos + .5 * dt * wk1[x, y, z]
                wk2[x, y, z] = interp_component_u_at_p(grid.w, temp_pos, Component.W, grid)
                temp_pos[:] = pos + .75 * dt * wk2[x, y, z]
                wk3[x, y, z] = interp_component_u_at_p(grid.w, temp_pos, Component.W, grid)
                new_w[x, y, z] = grid.w[x, y, z] + (2/9) * dt * wk1[x, y, z] + (3/9) * dt * wk2[x, y, z] + (4/9) * dt * wk3[x, y, z]
    grid.u[:, :, :] = new_u
    grid.v[:, :, :] = new_v
    grid.w[:, :, :] = new_w
    apply_velocity_boundary_conditions(grid)

# -- Pressure Solve --

cpdef double get_vel(MACGrid grid, int x, int y, int z):
    # Gets max velocity in simulation during pressure solve for next dt calculation
    cdef double u = interp_dir(grid.u[x, y, z], grid.u[x-1, y, z], 0.5)
    cdef double v = interp_dir(grid.v[x, y, z], grid.v[x, y-1, z], 0.5)
    cdef double w = interp_dir(grid.w[x, y, z], grid.w[x, y, z-1], 0.5)
    return (u**2+v**2+w**2)**0.5

cpdef void apply_pressure_boundary_conditions(MACGrid grid):
    # Neumann boundary conditions (zero gradient at boundaries)
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    for y in range(ny):
        for z in range(nz):
            grid.pressure[0, y, z] = grid.pressure[1, y, z]
            grid.pressure[nx-1, y, z] = grid.pressure[nx-2, y, z]
    for x in range(nx):
        for z in range(nz):
            grid.pressure[x, 0, z] = grid.pressure[x, 1, z]
            grid.pressure[x, ny-1, z] = grid.pressure[x, ny-2, z]
    for x in range(nx):
        for y in range(ny):
            grid.pressure[x, y, 0] = grid.pressure[x, y, 1]
            grid.pressure[x, y, nz-1] = grid.pressure[x, y, nz-2]

cpdef void apply_velocity_boundary_conditions(MACGrid grid):
    # No-slip condition at boundaries
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    for y in range(ny):
        for z in range(nz):
            grid.u[0, y, z] = 0.0
            grid.u[nx, y, z] = 0.0  
    for x in range(nx):
        for z in range(nz):
            grid.v[x, 0, z] = 0.0
            grid.v[x, ny, z] = 0.0  
    for x in range(nx):
        for y in range(ny):
            grid.w[x, y, 0] = 0.0
            grid.w[x, y, nz] = 0.0  

#cpdef void build_sparse(MACGrid grid):

cpdef void cy_pressure_solve(MACGrid grid, double dt, int iterations=50):
    cdef int x, y, z
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef double h = grid.cell_size
    cdef double max_vel = 0
    cdef cnp.ndarray rhs
    cdef int info = 0

    # Build the sparse matrix for the pressure equation
    cdef object A = grid.build_sparse()

    # Calculate divergence
    for x in range(1, nx-1):
        for y in range(1, ny-1):
            for z in range(1, nz-1):
                u_diff = grid.u[x+1, y, z] - grid.u[x, y, z]
                v_diff = grid.v[x, y+1, z] - grid.v[x, y, z]
                w_diff = grid.w[x, y, z+1] - grid.w[x, y, z]

                # Update divergence
                grid.divergence[x, y, z] = (u_diff + v_diff + w_diff) / h

                # Update max velocity
                max_vel = max(max_vel, get_vel(grid, x, y, z))

    grid.max_vel = max_vel

    # Prepare the right-hand side (rhs) for the pressure equation
    rhs = np.nan_to_num(grid.divergence.flatten())

    # Solve the pressure equation using the Conjugate Gradient method
    grid.pressure, info = cg(A, rhs, x0=grid.pressure.flatten(), maxiter=iterations)

    # Reshape pressure back to 3D
    grid.pressure = grid.pressure.reshape((nx, ny, nz))

    # Check solver information
    print("CG solver finished with info code:", info)
    print("Resulting pressure min:", np.min(grid.pressure), "max:", np.max(grid.pressure))


# -- Pressure Projection --

cpdef void cy_project(MACGrid grid):
    cdef int x, y, z
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef double h = grid.cell_size
    for x in range(nx):
        for y in range(ny):
            for z in range(nz):
                if x > 0 and grid.solid_mask[x, y, z] == 0 and grid.solid_mask[x-1, y, z] == 0:
                    grid.u[x, y, z] -= (grid.pressure[x, y, z] - grid.pressure[x-1, y, z]) / h
                if y > 0 and grid.solid_mask[x, y, z] == 0 and grid.solid_mask[x, y-1, z] == 0:
                    grid.v[x, y, z] -= (grid.pressure[x, y, z] - grid.pressure[x, y-1, z]) / h
                if z > 0 and grid.solid_mask[x, y, z] == 0 and grid.solid_mask[x, y, z-1] == 0:
                    grid.w[x, y, z] -= (grid.pressure[x, y, z] - grid.pressure[x, y, z-1]) / h

    apply_velocity_boundary_conditions(grid)

    # Debugging output to check velocity updates
    print("Velocity after pressure projection:")
    print("Min u:", np.min(grid.u), "Max u:", np.max(grid.u))
    print("Min v:", np.min(grid.v), "Max v:", np.max(grid.v))
    print("Min w:", np.min(grid.w), "Max w:", np.max(grid.w))


# -- Final Advection --

cpdef void cy_advect_density(MACGrid grid, double dt):
    # Advect density scalar with RK3 method
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    cdef cnp.npy_intp x, y, z
    cdef double cell_size = grid.cell_size
    cdef cnp.ndarray new_density
    cdef cnp.ndarray pos = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray temp_pos = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray k1 = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray k2 = np.zeros(3, dtype=np.float64)
    cdef cnp.ndarray k3 = np.zeros(3, dtype=np.float64)
    new_density = np.zeros_like(grid.density)
    for x in range(nx):
        for y in range(ny):
            for z in range(nz):
                pos[:] = grid.get_cell_position(x, y, z)
                k1[:] = interp_u_at_p(grid, pos)
                temp_pos[:] = pos + 0.5 * dt * k1
                k2[:] = interp_u_at_p(grid, temp_pos)
                temp_pos[:] = pos + 0.75 * dt * k2
                k3[:] = interp_u_at_p(grid, temp_pos)
                temp_pos[:] = pos + (2/9) * dt * k1 + (3/9) * dt * k2 + (4/9) * dt * k3
                new_density[x, y, z] = interp_scalar_u_at_p(grid.density, temp_pos, cell_size)
                grid.position[x, y, z, :] = temp_pos
    grid.density[:, :, :] = new_density

# -- Simulation main --

cpdef void cy_simulate(MACGrid grid, cnp.ndarray wind, double initial_dt, 
        object bvh_tree, cnp.ndarray wind_speed, cnp.ndarray wind_acceleration, 
        double damping_factor, double cell_size, double friction):
    cdef double t = 0.0
    cdef double tframe = 1.0
    cdef double dt
    cdef cnp.npy_intp nx = grid.grid_size[0]
    cdef cnp.npy_intp ny = grid.grid_size[1]
    cdef cnp.npy_intp nz = grid.grid_size[2]
    grid.divergence = np.zeros((nx, ny, nz), dtype=np.float64)
    while t < tframe:
        dt = min(calc_dt(grid, initial_dt, cell_size, wind_acceleration), tframe - t)
        cy_predict_wind(grid, 1, wind_speed, wind_acceleration, damping_factor)
        cy_advect_velocities(grid, dt)
        cy_collide(grid, bvh_tree, dt, damping_factor, friction) 
        cy_pressure_solve(grid, dt, iterations=50)
        cy_project(grid)
        cy_advect_velocities(grid, dt)
        cy_advect_density(grid, dt)
        t += dt

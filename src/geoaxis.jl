using Makie: left, right, top, bottom
using Makie.MakieLayout: height, width

"""
    GeoAxis(fig_or_scene; kwargs...) → ax::Axis

Create a modified `Axis` of the Makie.jl ecosystem.
All Makie.jl plotting functions work directly on `GeoAxis`, e.g., `scatter!(ax, x, y)`.

This is because it _is_ a regular `Axis` - along with the functions like `xlims!` and
attributes like `ax.xticks`, et cetera.

`GeoAxis` is appropriate for geospatial plotting because it automatically transforms all
plotted data given a user-defined map projection. See keyword arguments below and examples
in the online documentation. Longitude and latitude values in GeoMakie.jl are always
assumed to be **in degrees**.

In order to automatically adjust the limits to your data, you can call `datalims!(ax)`
on any `GeoAxis`.  Note that if your data is not adjusted to the WGS84 datum

In the call signature, `fig_or_scene` can be a standard figure location, e.g., `fig[1,1]` as given in
`Axis`. The keyword arguments decide the geospatial projection.

## Keyword arguments

* `source = "+proj=longlat +datum=WGS84", dest = "+proj=eqearth"`: These two keywords
  configure the map projection to be used for the given field using Proj.jl.
  See also online the section [Changing central longitude](@ref) for data that may not
  span the (expected by default) longitude range from -180 to 180.
* `transformation = Proj.Transformation(source, dest, always_xy=true)`: Instead of
  `source, dest`, you can directly use the Proj.jl package to define the projection.
* `lonlims = (-180, 180)`: The limits for longitude (x-axis).  For automatic
  determination, pass `lonlims=automatic`.
* `latlims = (-90, 90)`: The limits for latitude (y-axis).  For automatic
  determination, pass `latlims=automatic`.
* `coastlines = false`: Draw the coastlines of the world, from the Natural Earth dataset.
* `coastline_attributes = (;)`: Attributes that get passed to the `lines` call drawing the coastline.
* `line_density = 1000`: The number of points sampled per grid line.  Do not set this higher than 10,000.
* `remove_overlapping_ticks = true`: Remove ticks which could overlap each other.  Y-axis ticks take priority
  over x-axis ticks.

## Example

```julia
using GeoMakie
fig = Figure()
ax = GeoAxis(fig[1,1]; coastlines = true)
image!(ax, -180..180, -90..90, rotr90(GeoMakie.earth()); interpolate = false)
el = scatter!(rand(-180:180, 5), rand(-90:90, 5); color = rand(RGBf, 5))
fig

```
"""
function GeoAxis(args...;
        source = "+proj=longlat +datum=WGS84", dest = "+proj=eqearth",
        transformation = Proj.Transformation(Makie.to_value(source), Makie.to_value(dest), always_xy=true),
        lonlims = (-180, 180),
        latlims = (-90, 90),
        coastlines = false,
        coastline_attributes = (;label = "Coastlines",),
        line_density = 1_000,
        remove_overlapping_ticks = true,
        # these are the axis keywords which we will merge in
        xtickformat = geoformat_ticklabels,
        ytickformat = geoformat_ticklabels,
        xticks = LinearTicks(7),
        yticks = LinearTicks(7),
        xticklabelpad = 5.0,
        yticklabelpad = 5.0,
        xticklabelalign = (:center, :center),
        yticklabelalign = (:center, :center),
        kw...
    )


    _transformation = Observable{Proj.Transformation}(Makie.to_value(transformation))
     Makie.Observables.onany(source, dest) do src, dst
        _transformation[] = Proj.Transformation(Makie.to_value(src), Makie.to_value(dest); always_xy = true)
    end
    Makie.Observables.onany(transformation) do trans
        _transformation[] = trans
    end

    # Automatically determine limits!
    # TODO: should we automatically verify limits
    # or not?
    axmin, axmax, aymin, aymax = find_transform_limits(_transformation[])

    verified_lonlims = lonlims
    if lonlims == Makie.automatic
        verified_lonlims = axmin < axmax ? (axmin, axmax) : (axmax, axmin)
    end
    verified_latlims = latlims
    if latlims == Makie.automatic
        verified_latlims = aymin < aymax ? (aymin, aymax) : (aymax, aymin)
    end
    # Apply defaults
    # Generate Axis instance
    ax = Axis(args...;
        aspect = DataAspect(),
        xtickformat = xtickformat,
        ytickformat = ytickformat,
        xticks = xticks,
        yticks = yticks,
        limits = (verified_lonlims, verified_latlims),
        kw...)


    # Set axis transformation
    Makie.Observables.connect!(ax.scene.transformation.transform_func, _transformation)

    # Plot coastlines
    coastplot = lines!(ax, GeoMakie.coastlines(); color = :black, coastline_attributes...)
    translate!(coastplot, 0, 0, 99) # ensure they are on top of other plotted elements
    xprot = ax.xaxis.protrusion[]
    yprot = ax.yaxis.protrusion[]
    if !coastlines
        delete!(ax, coastplot)
    end

    # Set the axis's native grid to always be invisible, and
    # forward those updates to our observables.
    # First we need to hijack the axis's protrusions and store them

    hijacked_observables = Dict{Symbol, Observable}()
    ## This macro is defined in `utils.jl`
    @hijack_observable :xgridvisible
    @hijack_observable :ygridvisible
    @hijack_observable :xticksvisible
    @hijack_observable :yticksvisible
    # @hijack_observable :xticklabelsvisible
    # @hijack_observable :yticklabelsvisible
    @hijack_observable :topspinevisible
    @hijack_observable :bottomspinevisible
    @hijack_observable :leftspinevisible
    @hijack_observable :rightspinevisible


    # WARNING: for now, we only accept xticks on the bottom
    # and yticks on the left.

    draw_geoticks!(ax, hijacked_observables, line_density, remove_overlapping_ticks)

    ax.xaxis.protrusion[] = xprot
    ax.yaxis.protrusion[] = yprot

    return ax
end

function draw_geoticks!(ax::Axis, hijacked_observables, line_density, remove_overlapping_ticks)
    topscene = ax.blockscene
    scene = ax.scene

    decorations = Dict{Symbol, Any}()

    xgridpoints = Observable(Point2f[])
    ygridpoints = Observable(Point2f[])

    xtickpoints = Observable(Point2f[])
    ytickpoints = Observable(Point2f[])

    xticklabels = Observable(String[])
    yticklabels = Observable(String[])

    topspinepoints = Observable(Point2f[])
    btmspinepoints = Observable(Point2f[])
    lftspinepoints = Observable(Point2f[])
    rgtspinepoints = Observable(Point2f[])

    xlimits = Observable((0.0f0, 0.0f0))
    ylimits = Observable((0.0f0, 0.0f0))
    # First we establish the spine points

    lift(ax.finallimits, ax.xticks, ax.xtickformat, ax.yticks, ax.ytickformat, ax.scene.px_area, getproperty(ax.scene, :transformation).transform_func) do limits, xticks, xtickformat, yticks, ytickformat, pxarea, _tfunc

        lmin = minimum(limits)
        lmax = maximum(limits)
        xlimits[] = (lmin[1], lmax[1])
        ylimits[] = (lmin[2], lmax[2])

        _xtickvalues, _xticklabels = Makie.MakieLayout.get_ticks(xticks, identity, xtickformat, xlimits[]...)
        _ytickvalues, _yticklabels = Makie.MakieLayout.get_ticks(yticks, identity, ytickformat, ylimits[]...)

        _xtickpos_in_inputspace = Point2f.(_xtickvalues, ylimits[][1])
        _ytickpos_in_inputspace = Point2f.(xlimits[][1], _ytickvalues)

        # Find the necessary padding for each tick
        xticklabelpad = directional_pad.(
            Ref(scene), Ref(limits), _xtickpos_in_inputspace,
            _xticklabels, Ref(Point2f(0, ax.xticklabelpad[])), ax.xticklabelsize[], ax.xticklabelfont[],
            ax.xticklabelrotation[]
        )
        yticklabelpad = directional_pad.(
            Ref(scene), Ref(limits), _ytickpos_in_inputspace,
            _yticklabels, Ref(Point2f(ax.yticklabelpad[], 0)), ax.yticklabelsize[], ax.yticklabelfont[],
            ax.yticklabelrotation[]
        )

        # update but do not notify
        xtickpoints.val = project_to_pixelspace(scene, _xtickpos_in_inputspace) .+
                            Ref(Point2f(pxarea.origin)) .+ xticklabelpad


        ytickpoints.val = project_to_pixelspace(scene, _ytickpos_in_inputspace) .+
                            Ref(Point2f(pxarea.origin)) .+ yticklabelpad

        # check for overlapping ticks and remove them (literally deleteat!(...))
        remove_overlapping_ticks && remove_overlapping_ticks!(
            scene,
            xtickpoints.val, _xticklabels, ax.xticklabelsvisible[],
            ytickpoints.val, _yticklabels, ax.yticklabelsvisible[],
            max(ax.xticklabelsize[], ax.yticklabelsize[])
        )

        # notify this
        xticklabels[] = _xticklabels
        yticklabels[] = _yticklabels

        Makie.Observables.notify(xtickpoints); Makie.Observables.notify(ytickpoints)

        xrange = LinRange(xlimits[]..., line_density)
        yrange = LinRange(ylimits[]..., line_density)

        # first update the spine
        topspinepoints[] = Point2f.(xrange, ylimits[][2])
        btmspinepoints[] = Point2f.(xrange, ylimits[][1])
        lftspinepoints[] = Point2f.(xlimits[][1], yrange)
        rgtspinepoints[] = Point2f.(xlimits[][2], yrange)

        # now, the grid.  Each visible "gridline" is separated from the next
        # by a `Point2f(NaN)`.  The approach here allows us to avoid appending.
        # x first
        _xgridpoints = fill(Point2f(NaN), (line_density+1) * length(_xtickvalues))

        current_ind = 1
        for x in _xtickvalues
            _xgridpoints[current_ind:(current_ind+line_density-1)] = Point2f.(x, yrange)
            current_ind += line_density + 1
        end
        # now y
        _ygridpoints = fill(Point2f(NaN), (line_density+1) * length(_ytickvalues))

        current_ind = 1
        for y in _ytickvalues
            _ygridpoints[current_ind:(current_ind+line_density-1)] = Point2f.(xrange, y)
            current_ind += line_density + 1
        end

        xgridpoints[] = _xgridpoints
        ygridpoints[] = _ygridpoints

        return 1
        # Now, we've updated the entire axis.
    end

    Makie.Observables.notify(ax.xticks)

    # Time to plot!

    # First, we plot the spines:

    decorations[:topspineplot] = lines!(
        scene, topspinepoints;
        visible = hijacked_observables[:topspinevisible],
        color = ax.topspinecolor,
        # linestyle = ax.spinestyle,
        linewidth = ax.spinewidth,
        )
    decorations[:btmspineplot] = lines!(
        scene, btmspinepoints;
        visible = hijacked_observables[:bottomspinevisible],
        color = ax.bottomspinecolor,
        # linestyle = ax.spinestyle,
        linewidth = ax.spinewidth,
        )
    decorations[:lftspineplot] = lines!(
        scene, lftspinepoints;
        visible = hijacked_observables[:leftspinevisible],
        color = ax.leftspinecolor,
        # linestyle = ax.spinestyle,
        linewidth = ax.spinewidth,
        )
    decorations[:rgtspineplot] = lines!(
        scene, rgtspinepoints;
        visible = hijacked_observables[:rightspinevisible],
        color = ax.rightspinecolor,
        # linestyle = ax.spinestyle,
        linewidth = ax.spinewidth,
        )


    # Now for the grids:

    decorations[:xgridplot] = lines!(
        scene, xgridpoints;
        visible = hijacked_observables[:xgridvisible],
        color = ax.xgridcolor,
        linestyle = ax.xgridstyle,
        width = ax.xgridwidth,
    )
    decorations[:ygridplot] = lines!(
        scene, ygridpoints;
        visible = hijacked_observables[:ygridvisible],
        color = ax.ygridcolor,
        linestyle = ax.ygridstyle,
        width = ax.ygridwidth,
    )


    # And finally, the TikZ!

    textscene = ax.blockscene

    # decorations[:xtickplot] = text!(
    #     textscene,
    #     xticklabels;
    #     markerspace = :pixel,
    #     visible = hijacked_observables[:xticklabelsvisible],
    #     position = xtickpoints,
    #     rotation = ax.xticklabelrotation,
    #     font = ax.xticklabelfont,
    #     textsize = ax.xticklabelsize,
    #     color = ax.xticklabelcolor,
    #     align = (:center, :center),
    # )
    #
    # decorations[:ytickplot] = text!(
    #     textscene,
    #     yticklabels;
    #     markerspace = :pixel,
    #     visible = hijacked_observables[:yticklabelsvisible],
    #     position = ytickpoints,
    #     rotation = ax.yticklabelrotation,
    #     font = ax.yticklabelfont,
    #     textsize = ax.yticklabelsize,
    #     color = ax.yticklabelcolor,
    #     align = (:center, :center),
    # )


    # Currently, I hijack the axis text for this.  However, I don't know what it would do
    # to interaction times, hence why I have left the old code commented out above.
    Makie.Observables.connect!(ax.blockscene.plots[end-3][1], Makie.@lift tuple.($yticklabels, $ytickpoints))
    Makie.Observables.connect!(ax.blockscene.plots[end-8][1], Makie.@lift tuple.($xticklabels, $xtickpoints))

    # For diagnostics only!
    # scatter!(textscene, xtickpoints; visible = hijacked_observables[:xticklabelsvisible], color = :red, bordercolor=:black)
    # scatter!(textscene, ytickpoints; visible = hijacked_observables[:yticklabelsvisible], color = :red, bordercolor=:black)

    # Finally, we translate these plots such that they are above the content.
    translate!.(values(decorations), 0, 0, 100)

    # Set common attributes for all plots
    setproperty!.(values(decorations), Ref(:inspectable), Ref(false))
    setproperty!.(values(decorations), Ref(:xautolimits), Ref(false))
    setproperty!.(values(decorations), Ref(:yautolimits), Ref(false))

    return decorations
end



function _datalims_exclude(plot)
    !(to_value(get(plot, :xautolimits, true)) || to_value(get(plot, :yautolimits, true))) ||
    !Makie.is_data_space(to_value(get(plot, :space, :data))) ||
    !to_value(get(plot, :visible, true))
end
# Applicable only to geoaxis
# in the future, once PolarAxis is implemented as an example,
# change this to `Makie.data_limits(ax::GeoAxis)`
function datalims(ax::Axis)
    nplots = length(plots(ax.scene))

    n_axisplots = if nplots ≥ 8 &&
                    ax.scene.plots[2] isa Makie.Lines &&
                    haskey(ax.scene.plots[2], :label) &&
                    ax.scene.plots[2].label[] == "Coastlines"
                8
        else
                7
        end

    return Makie.data_limits(ax.scene.plots[(n_axisplots+1):end], _datalims_exclude)

end

function datalims!(ax::Axis)
    lims = datalims(ax)
    min = lims.origin[1:2]
    max = lims.widths[1:2] .+ lims.origin[1:2]
    xlims!(ax, min[1], max[1])
    ylims!(ax, min[2], max[2])
    return (min[1], max[1], min[2], max[2])
end

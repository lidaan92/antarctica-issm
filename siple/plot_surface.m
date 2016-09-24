function plot_surface(dataset)

figure

imagesc(dataset.x, dataset.y, dataset.surface);
axis xy equal tight

title('Surface elevation')
xlabel('x [m]')
ylabel('y [m]')

cb = colorbar();
ylabel(cb,'H [m]')

end
import { useEffect, useRef } from 'react';
export function Chart({ option, height = 260, label, onZoom }) {
    const node = useRef(null);
    const chart = useRef(null);
    const zoom = useRef(onZoom);
    const currentOption = useRef(option);
    zoom.current = onZoom;
    currentOption.current = option;
    useEffect(() => {
        let timer;
        let zoomTimer;
        let observer;
        function mount() {
            if (!window.echarts) {
                timer = setTimeout(mount, 50);
                return;
            }
            chart.current = window.echarts.init(node.current, null, { renderer: 'canvas' });
            chart.current.on('datazoom', event => {
                if (!zoom.current) return;
                const selection = event.batch?.[0] || event;
                const stamps = currentOption.current.series?.[0]?.data?.map(row => row[0]) || [];
                if (stamps.length < 2) return;
                const first = Math.min(...stamps), last = Math.max(...stamps);
                const start = Number(selection.startValue ?? first + (last - first) * (selection.start ?? 0) / 100);
                const end = Number(selection.endValue ?? first + (last - first) * (selection.end ?? 100) / 100);
                clearTimeout(zoomTimer);
                zoomTimer = setTimeout(() => zoom.current?.({start: Math.floor(start / 1000), end: Math.ceil(end / 1000)}), 400);
            });
            observer = new ResizeObserver(() => chart.current?.resize());
            observer.observe(node.current);
            chart.current.setOption(option);
        }
        mount();
        return () => { clearTimeout(timer); clearTimeout(zoomTimer); observer?.disconnect(); chart.current?.dispose(); chart.current = null; };
    }, []);
    useEffect(() => { chart.current?.setOption(option, { notMerge: true, lazyUpdate: true }); }, [option]);
    return <div ref={node} className="chart" role="img" aria-label={label} style={{ height }}/>;
}
const colors = ['#38bdf8', '#34d399', '#fbbf24', '#fb7185', '#a78bfa'];
const base = { animationDuration: 250, color: colors, textStyle: { fontFamily: 'system-ui, sans-serif', color: '#8396ad' } };
export function lineOption(rows, fields, { zoom = false } = {}) {
    return { ...base,
        tooltip: { trigger: 'axis', confine: true },
        legend: { bottom: 0, textStyle: { color: '#8396ad' }, icon: 'circle', itemWidth: 8 },
        grid: { left: 54, right: 18, top: 24, bottom: zoom ? 86 : 52 },
        xAxis: { type: 'time', axisLine: { show: false }, splitLine: { show: false } },
        yAxis: { type: 'value', splitLine: { lineStyle: { color: '#8396ad22' } }, axisLabel: { formatter: '{value}' } },
        ...(zoom ? { dataZoom: [{ type: 'inside' }, { type: 'slider', bottom: 28, height: 18 }] } : {}),
        series: fields.map(([key, name], i) => ({ name, type: 'line', showSymbol: false, smooth: 0.15,
            lineStyle: { width: 2 }, areaStyle: i === 0 ? { opacity: 0.09 } : undefined,
            data: rows.map(row => [Number(row.stamp ?? row.timestamp ?? row.bucket ?? row.time) * 1000, row[key] ?? null]) })),
    };
}
export function donutOption(rows) {
    return { ...base, tooltip: { trigger: 'item', confine: true },
        legend: { bottom: 0, textStyle: { color: '#8396ad' }, icon: 'circle', itemWidth: 8 },
        series: [{ type: 'pie', radius: ['55%', '76%'], center: ['50%', '44%'],
                label: { show: false }, emphasis: { label: { show: true, fontSize: 16, fontWeight: 'bold', formatter: '{b}\n{d}%' } },
                data: rows.map(row => ({ name: row.name ?? row.key ?? row.value ?? 'Unknown', value: row.calls ?? row.count ?? row.requests ?? 0 })) }],
    };
}

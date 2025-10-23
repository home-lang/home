import { Router, Request, Response } from 'express';
import { mongoDb, logger } from '../server';

export const statsRouter = Router();

// GET /api/stats - Get registry statistics
statsRouter.get('/', async (req: Request, res: Response) => {
    try {
        const totalPackages = await mongoDb.collection('packages').countDocuments();
        const totalUsers = await mongoDb.collection('users').countDocuments();

        const totalDownloads = await mongoDb.collection('packages').aggregate([
            {
                $group: {
                    _id: null,
                    total: { $sum: '$downloadCount' }
                }
            }
        ]).toArray();

        const topPackages = await mongoDb
            .collection('packages')
            .find({})
            .sort({ downloadCount: -1 })
            .limit(10)
            .project({ name: 1, downloadCount: 1, description: 1 })
            .toArray();

        const recentPackages = await mongoDb
            .collection('packages')
            .find({})
            .sort({ createdAt: -1 })
            .limit(10)
            .project({ name: 1, description: 1, latestVersion: 1, createdAt: 1 })
            .toArray();

        res.json({
            totalPackages,
            totalUsers,
            totalDownloads: totalDownloads[0]?.total || 0,
            topPackages,
            recentPackages
        });
    } catch (error) {
        logger.error('Error fetching stats', { error });
        res.status(500).json({ error: 'Failed to fetch statistics' });
    }
});

// GET /api/stats/package/:name - Get package statistics
statsRouter.get('/package/:name', async (req: Request, res: Response) => {
    try {
        const { name } = req.params;

        const pkg = await mongoDb.collection('packages').findOne({ name });

        if (!pkg) {
            return res.status(404).json({ error: 'Package not found' });
        }

        // Get download stats over time (would require tracking downloads by date)
        const stats = {
            name: pkg.name,
            totalDownloads: pkg.downloadCount,
            totalVersions: pkg.versions.length,
            latestVersion: pkg.latestVersion,
            publishedAt: pkg.createdAt,
            lastUpdated: pkg.updatedAt
        };

        res.json(stats);
    } catch (error) {
        logger.error('Error fetching package stats', { error, name: req.params.name });
        res.status(500).json({ error: 'Failed to fetch package statistics' });
    }
});
